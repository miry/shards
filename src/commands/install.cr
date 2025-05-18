require "./command"
require "../molinillo_solver"

module Shards
  module Commands
    class Install < Command
      def run
        if Shards.frozen? && !lockfile?
          raise Error.new("Missing shard.lock")
        end
        check_symlink_privilege

        Log.info { "Resolving dependencies" }

        solver = MolinilloSolver.new(spec, override)

        if lockfile?
          # install must be as conservative as possible:
          solver.locks = locks.shards
        end

        solver.prepare(development: Shards.with_development?)

        packages = handle_resolver_errors { solver.solve }
        Log.trace { "packages = #{packages}" }

        if Shards.frozen?
          validate(packages)
        end

        Log.trace { "Installing..." }
        install(packages)

        Log.trace { "Generate lockfile..." }
        if generate_lockfile?(packages)
          Log.trace { "Write lockfile..." }
          write_lockfile(packages)
        elsif !Shards.frozen?
          # Touch lockfile so its mtime is bigger than that of shard.yml
          File.touch(lockfile_path)
        end

        # Touch install path so its mtime is bigger than that of the lockfile
        touch_install_path

        check_crystal_version(packages)
      end

      private def validate(packages)
        packages.each do |package|
          if lock = locks.shards.find { |d| d.name == package.name }
            if lock.resolver != package.resolver
              raise LockConflict.new("#{package.name} source changed")
            else
              validate_locked_version(package, lock.version)
            end
          else
            raise LockConflict.new("can't install new dependency #{package.name} in production")
          end
        end
      end

      private def validate_locked_version(package, version)
        return if package.version == version
        raise LockConflict.new("#{package.name} requirements changed")
      end

      private def install(packages : Array(Package))
        # packages are returned by the solver in reverse topological order,
        # so transitive dependencies are installed first
        packages.each do |package|
          Log.with_context do
            Log.context.set package: package.name
            # first install the dependency:
            next unless install(package)

            # then execute the postinstall script
            # (with access to all transitive dependencies):
            package.postinstall

            # always install executables because the path resolver never actually
            # installs dependencies:
            package.install_executables
          end
        end
      end

      private def install(package : Package)
        if package.installed?
          Log.info { "Using #{package.name} (#{package.report_version})" }
          return
        end

        Log.info { "Installing #{package.name} (#{package.report_version})" }
        package.install
        package
      end

      private def generate_lockfile?(packages)
        !Shards.frozen? && (!lockfile? || outdated_lockfile?(packages))
      end

      private def outdated_lockfile?(packages)
        return true if locks.version != Shards::Lock::CURRENT_VERSION
        return true if packages.size != locks.shards.size

        packages.index_by(&.name) != locks.shards.index_by(&.name)
      end
    end
  end
end
