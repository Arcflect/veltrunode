# frozen_string_literal: true

require_relative 'model/application'
require_relative 'model/function'
require_relative 'model/layer'
require_relative 'model/schedule'
require_relative 'model/efs_mount'
require_relative 'model/capability'
require_relative 'model/capability_expander'

module Veltrunode
  module Model
  end

  Application = Model::Application
  Function = Model::Function
  Layer = Model::Layer
  Schedule = Model::Schedule
  EfsMount = Model::EfsMount
  Capability = Model::Capability
  CapabilityExpander = Model::CapabilityExpander
end
