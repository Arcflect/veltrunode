# frozen_string_literal: true

require 'yaml'
require_relative '../logical_id'
require_relative '../../model/managed_access_point'

module Veltrunode
  module Compiler
    module CloudFormation
      # AWS::EFS::FileSystem リソースのコンパイラ
      class FileSystemCompiler
        attr_reader :mount, :options, :context

        class << self
          def compile(mount, **)
            new(mount, **).to_h
          end

          def to_yaml(mount, **)
            new(mount, **).to_yaml
          end

          def logical_id_for(name)
            LogicalId.for_file_system(name)
          end

          def pascalize(str)
            LogicalId.pascalize(str)
          end
        end

        def initialize(mount, options: {}, context: {})
          @mount = mount
          @options = freeze_hash(options)
          @context = freeze_hash(context)
        end

        def logical_id
          self.class.logical_id_for(mount_name)
        end

        def resource_type
          'AWS::EFS::FileSystem'
        end

        def to_h
          deep_sort_keys(
            logical_id => {
              'Type' => resource_type,
              'Properties' => properties
            }
          )
        end

        def to_yaml
          YAML.dump(to_h)
        end

        def properties
          props = {}
          policies = format_lifecycle_policies
          props['LifecyclePolicies'] = policies unless policies.empty?

          tp_mode, prov_tp = format_throughput_config
          props['ThroughputMode'] = tp_mode if tp_mode
          props['ProvisionedThroughputInMibps'] = prov_tp unless prov_tp.nil?

          enc_val, kms_val = format_encryption_config
          props['Encrypted'] = enc_val unless enc_val.nil?
          props['KmsKeyId'] = kms_val unless kms_val.nil?

          props
        end

        private

        def mount_name
          if mount.respond_to?(:symbolic_name)
            mount.symbolic_name
          elsif mount.respond_to?(:name)
            mount.name
          elsif mount.is_a?(Hash)
            mount[:symbolic_name] || mount['symbolic_name'] || mount[:name] || mount['name']
          else
            mount.to_s
          end
        end

        def format_lifecycle_policies
          raw = extract_lifecycle_policies
          Model::ManagedAccessPoint.to_cfn_lifecycle_policies(raw)
        end

        def format_throughput_config
          raw_mode = extract_throughput_mode
          raw_prov = extract_provisioned_throughput
          return [nil, nil] if raw_mode.nil? && raw_prov.nil?

          Model::ManagedAccessPoint.normalize_throughput_config(
            throughput_mode: raw_mode,
            provisioned_throughput_in_mibps: raw_prov
          )
        end

        def format_encryption_config
          raw_enc = extract_encrypted
          raw_kms = extract_kms_key_id
          return [nil, nil] if raw_enc.nil? && raw_kms.nil?

          enc, kms = Model::ManagedAccessPoint.normalize_encryption_config(
            encrypted: raw_enc,
            kms_key_id: raw_kms
          )
          [enc, format_kms_key_value(kms)]
        end

        def format_kms_key_value(kms)
          return nil if kms.nil?

          if kms.is_a?(Hash)
            ref_sym = kms[:ref] || kms['ref']
            return { 'Ref' => LogicalId.pascalize(ref_sym) } if ref_sym

            ref_lit = kms[:Ref] || kms['Ref']
            return { 'Ref' => ref_lit.to_s } if ref_lit

            return kms
          end

          return { 'Ref' => LogicalId.pascalize(kms.name) } if !kms.is_a?(Symbol) && kms.respond_to?(:name)
          return { 'Ref' => LogicalId.pascalize(kms) } if kms.is_a?(Symbol)

          kms.to_s
        end

        def extract_encrypted
          if mount.respond_to?(:encrypted) && !mount.encrypted.nil?
            mount.encrypted
          elsif mount.respond_to?(:managed_access_point) && !mount.managed_access_point&.encrypted.nil?
            mount.managed_access_point.encrypted
          elsif mount.is_a?(Hash)
            extract_hash_encrypted(mount)
          end
        end

        def extract_hash_encrypted(hash)
          %i[encrypted Encrypted].each do |k|
            return hash[k] if hash.key?(k)
            return hash[k.to_s] if hash.key?(k.to_s)
          end
          extract_hash_ap_field(hash, :encrypted, 'encrypted')
        end

        def extract_kms_key_id
          if mount.respond_to?(:kms_key_id) && !mount.kms_key_id.nil?
            mount.kms_key_id
          elsif mount.respond_to?(:managed_access_point) && !mount.managed_access_point&.kms_key_id.nil?
            mount.managed_access_point.kms_key_id
          elsif mount.is_a?(Hash)
            mount[:kms_key_id] || mount['kms_key_id'] ||
              mount[:kms_key] || mount['kms_key'] ||
              mount[:kms_key_arn] || mount['kms_key_arn'] ||
              mount[:KmsKeyId] || mount['KmsKeyId'] ||
              extract_hash_ap_field(mount, :kms_key_id, 'kms_key_id')
          end
        end

        def extract_throughput_mode
          if mount.respond_to?(:throughput_mode) && mount.throughput_mode
            mount.throughput_mode
          elsif mount.respond_to?(:managed_access_point) && mount.managed_access_point&.throughput_mode
            mount.managed_access_point.throughput_mode
          elsif mount.is_a?(Hash)
            mount[:throughput_mode] || mount['throughput_mode'] ||
              mount[:ThroughputMode] || mount['ThroughputMode'] ||
              extract_hash_ap_field(mount, :throughput_mode, 'throughput_mode')
          end
        end

        def extract_provisioned_throughput
          if mount.respond_to?(:provisioned_throughput_in_mibps) && !mount.provisioned_throughput_in_mibps.nil?
            mount.provisioned_throughput_in_mibps
          elsif mount.respond_to?(:managed_access_point) &&
                !mount.managed_access_point&.provisioned_throughput_in_mibps.nil?
            mount.managed_access_point.provisioned_throughput_in_mibps
          elsif mount.is_a?(Hash)
            mount[:provisioned_throughput_in_mibps] || mount['provisioned_throughput_in_mibps'] ||
              mount[:provisioned_throughput] || mount['provisioned_throughput'] ||
              mount[:ProvisionedThroughputInMibps] || mount['ProvisionedThroughputInMibps'] ||
              extract_hash_ap_field(mount, :provisioned_throughput_in_mibps, 'provisioned_throughput_in_mibps')
          end
        end

        def extract_hash_ap_field(hash, sym_key, str_key)
          ap = hash[:managed_access_point] || hash['managed_access_point']
          return ap.public_send(sym_key) if ap.respond_to?(sym_key)
          return ap[sym_key] || ap[str_key] if ap.is_a?(Hash)

          nil
        end

        def extract_lifecycle_policies
          if mount.respond_to?(:lifecycle_policies) && mount.lifecycle_policies
            mount.lifecycle_policies
          elsif mount.respond_to?(:managed_access_point) && mount.managed_access_point&.lifecycle_policies
            mount.managed_access_point.lifecycle_policies
          elsif mount.is_a?(Hash)
            mount[:lifecycle_policies] || mount['lifecycle_policies'] ||
              mount[:lifecycle_policy] || mount['lifecycle_policy'] ||
              extract_from_hash_access_point(mount) ||
              mount
          end
        end

        def extract_from_hash_access_point(hash)
          ap = hash[:managed_access_point] || hash['managed_access_point']
          return ap.lifecycle_policies if ap.respond_to?(:lifecycle_policies)
          return ap[:lifecycle_policies] || ap['lifecycle_policies'] if ap.is_a?(Hash)

          nil
        end

        def deep_sort_keys(obj)
          case obj
          when Hash
            obj.keys.sort_by(&:to_s).to_h do |k|
              [k.to_s, deep_sort_keys(obj[k])]
            end
          when Array
            obj.map { |v| deep_sort_keys(v) }
          else
            obj
          end
        end

        def freeze_hash(hash)
          (hash || {}).dup.freeze
        end
      end
    end
  end
end
