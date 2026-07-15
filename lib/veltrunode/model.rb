module Veltrunode
  class Application
    attr_accessor :name, :region, :stage, :account, :runtime, :architecture, :functions, :layers, :schedules, :efs_mounts

    def initialize(name)
      @name = name
      @functions = {}
      @layers = {}
      @schedules = {}
      @efs_mounts = {}
    end
  end

  class Function
    attr_accessor :name, :handler, :memory, :timeout, :ephemeral_storage, :runtime, :architecture, :attached_layers, :mounts, :permissions

    def initialize(name)
      @name = name
      @attached_layers = []
      @mounts = []
      @permissions = []
    end
  end

  class Layer
    attr_accessor :name, :lockfile, :without, :build_on, :retain

    def initialize(name)
      @name = name
    end
  end

  class EfsMount
    attr_accessor :name, :access_point_arn, :local_path, :uid, :gid

    def initialize(name)
      @name = name
    end
  end

  class Schedule
    attr_accessor :name, :target, :cron, :rate, :at, :timezone, :input, :retry_policy, :dead_letter_queue

    def initialize(name)
      @name = name
    end
  end
end
