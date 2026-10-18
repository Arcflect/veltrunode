# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'veltrunode/build/sbom_generator'
require 'veltrunode/model/application'
require 'veltrunode/model/layer'

RSpec.describe Veltrunode::Build::SbomGenerator do
  def with_tmpdir(&)
    Dir.mktmpdir(&)
  end

  let(:sample_lockfile_content) do
    <<~LOCKFILE
      GEM
        remote: https://rubygems.org/
        specs:
          aws-eventstream (1.3.0)
          aws-partitions (1.890.0)
          aws-sdk-core (3.191.0)
            aws-eventstream (~> 1, >= 1.0.2)
            aws-partitions (~> 1, >= 1.651.0)
            aws-sigv4 (~> 1.8)
            jmespath (~> 1.0)
          aws-sdk-s3 (1.142.0)
            aws-sdk-core (~> 3, >= 3.191.0)
            aws-sigv4 (~> 1.8)
          aws-sigv4 (1.8.0)
          jmespath (1.6.2)

      PLATFORMS
        ruby

      DEPENDENCIES
        aws-sdk-s3 (~> 1.142)

      BUNDLED WITH
         2.5.6
    LOCKFILE
  end

  let(:layer) do
    Veltrunode::Model::Layer.new(
      name: 'gems',
      compatible_runtimes: ['ruby3.3'],
      source_spec: { 'lockfile' => 'Gemfile.lock' }
    )
  end

  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'converter-service',
      region: 'ap-northeast-1',
      stage: 'dev',
      layers: [layer]
    )
  end

  let(:fixed_time) { Time.utc(2026, 10, 18, 12, 0, 0) }

  describe '#build_data (CycloneDX format)' do
    it 'generates valid CycloneDX 1.5 JSON structure with components and dependency tree' do
      with_tmpdir do |tmpdir|
        File.write(File.join(tmpdir, 'Gemfile.lock'), sample_lockfile_content)

        generator = described_class.new(
          application: application,
          source_dir: tmpdir,
          format: :cyclonedx,
          built_at: fixed_time
        )
        data = generator.build_data

        expect(data['bomFormat']).to eq('CycloneDX')
        expect(data['specVersion']).to eq('1.5')
        expect(data['serialNumber']).to match(/\Aurn:uuid:[0-9a-f-]{36}\z/)
        expect(data['metadata']['timestamp']).to eq('2026-10-18T12:00:00Z')
        expect(data['metadata']['tools'].first['name']).to eq('Veltrunode')
        expect(data['metadata']['component']['name']).to eq('converter-service')

        # Check components
        components = data['components']
        expect(components).to be_an(Array)
        # aws-eventstream, aws-partitions, aws-sdk-core, aws-sdk-s3, aws-sigv4, jmespath
        expect(components.size).to eq(6)

        s3_comp = components.find { |c| c['name'] == 'aws-sdk-s3' }
        expect(s3_comp).not_to be_nil
        expect(s3_comp['version']).to eq('1.142.0')
        expect(s3_comp['purl']).to eq('pkg:gem/aws-sdk-s3@1.142.0')
        expect(s3_comp['type']).to eq('library')

        # Check dependency tree
        dependencies = data['dependencies']
        expect(dependencies).to be_an(Array)

        # App dependencies
        app_dep = dependencies.find { |d| d['ref'] == 'pkg:generic/converter-service@1.0.0' }
        expect(app_dep).not_to be_nil
        expect(app_dep['dependsOn']).to include('pkg:gem/aws-sdk-s3@1.142.0')

        # aws-sdk-s3 dependencies tree
        s3_dep = dependencies.find { |d| d['ref'] == 'pkg:gem/aws-sdk-s3@1.142.0' }
        expect(s3_dep).not_to be_nil
        expect(s3_dep['dependsOn']).to eq(['pkg:gem/aws-sdk-core@3.191.0', 'pkg:gem/aws-sigv4@1.8.0'])

        # aws-sdk-core dependencies tree
        core_dep = dependencies.find { |d| d['ref'] == 'pkg:gem/aws-sdk-core@3.191.0' }
        expect(core_dep).not_to be_nil
        expect(core_dep['dependsOn']).to eq(
          ['pkg:gem/aws-eventstream@1.3.0', 'pkg:gem/aws-partitions@1.890.0', 'pkg:gem/aws-sigv4@1.8.0',
           'pkg:gem/jmespath@1.6.2']
        )
      end
    end

    it 'resolves license information when gemspec is available' do
      with_tmpdir do |tmpdir|
        File.write(File.join(tmpdir, 'Gemfile.lock'), sample_lockfile_content)

        # Mock Gem::Specification for license resolution
        mock_spec = instance_double(Gem::Specification, licenses: ['Apache-2.0'])
        allow(Gem::Specification).to receive(:find_all_by_name).and_return([])
        allow(Gem::Specification).to receive(:find_all_by_name).with('aws-sdk-s3', '= 1.142.0').and_return([mock_spec])

        generator = described_class.new(
          application: application,
          source_dir: tmpdir,
          format: :cyclonedx,
          built_at: fixed_time
        )
        data = generator.build_data
        s3_comp = data['components'].find { |c| c['name'] == 'aws-sdk-s3' }

        expect(s3_comp['licenses']).to eq([{ 'license' => { 'id' => 'Apache-2.0' } }])
      end
    end
  end

  describe '#build_data (SPDX format)' do
    it 'generates valid SPDX 2.3 JSON structure with packages and relationships' do
      with_tmpdir do |tmpdir|
        File.write(File.join(tmpdir, 'Gemfile.lock'), sample_lockfile_content)

        generator = described_class.new(
          application: application,
          source_dir: tmpdir,
          format: :spdx,
          built_at: fixed_time
        )
        data = generator.build_data

        expect(data['spdxVersion']).to eq('SPDX-2.3')
        expect(data['dataLicense']).to eq('CC0-1.0')
        expect(data['SPDXID']).to eq('SPDXRef-DOCUMENT')
        expect(data['name']).to eq('converter-service')
        expect(data['creationInfo']['created']).to eq('2026-10-18T12:00:00Z')

        packages = data['packages']
        expect(packages.size).to eq(6)
        s3_pkg = packages.find { |p| p['name'] == 'aws-sdk-s3' }
        expect(s3_pkg).not_to be_nil
        expect(s3_pkg['SPDXID']).to eq('SPDXRef-Package-aws-sdk-s3-1.142.0')
        expect(s3_pkg['versionInfo']).to eq('1.142.0')

        relationships = data['relationships']
        s3_core_rel = relationships.find do |r|
          r['spdxElementId'] == 'SPDXRef-Package-aws-sdk-s3-1.142.0' &&
            r['relatedSpdxElement'] == 'SPDXRef-Package-aws-sdk-core-3.191.0'
        end
        expect(s3_core_rel).not_to be_nil
        expect(s3_core_rel['relationshipType']).to eq('DEPENDS_ON')
      end
    end
  end

  describe '#generate' do
    it 'writes pretty formatted JSON file to output_path and returns data' do
      with_tmpdir do |tmpdir|
        File.write(File.join(tmpdir, 'Gemfile.lock'), sample_lockfile_content)
        output_file = File.join(tmpdir, 'build', 'sbom.cdx.json')

        data = described_class.generate(
          application: application,
          source_dir: tmpdir,
          output_path: output_file,
          built_at: fixed_time
        )

        expect(File.exist?(output_file)).to be true
        expect(JSON.parse(File.read(output_file))).to eq(data)
      end
    end

    it 'handles missing Gemfile.lock gracefully and outputs empty components' do
      with_tmpdir do |tmpdir|
        output_file = File.join(tmpdir, 'build', 'sbom.cdx.json')

        data = described_class.generate(
          application: application,
          source_dir: tmpdir,
          output_path: output_file,
          built_at: fixed_time
        )

        expect(File.exist?(output_file)).to be true
        expect(data['components']).to eq([])
        expect(data['dependencies'].first['dependsOn']).to eq([])
      end
    end
  end
end
