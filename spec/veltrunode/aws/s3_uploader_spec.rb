# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'veltrunode/aws/s3_uploader'
require 'veltrunode/model/application'
require 'veltrunode/build/build_result'
require 'veltrunode/build/package_result'
require 'veltrunode/build/layer_package_result'

RSpec.describe Veltrunode::AWS::S3Uploader do
  let(:application) do
    Veltrunode::Model::Application.new(
      name: 'order-service',
      region: 'ap-northeast-1',
      stage: 'production'
    )
  end

  let(:mock_s3_client) { instance_double('Aws::S3::Client') }
  let(:bucket) { 'my-deployment-bucket' }
  subject(:uploader) { described_class.new(bucket: bucket, application: application, s3_client: mock_s3_client) }

  describe '#generate_key' do
    it 'formats S3 key with prefix, app, stage, content_hash, and name' do
      key = uploader.generate_key(name: 'worker', content_hash: 'abc12345')
      expect(key).to eq('veltrunode/order-service/production/abc12345/worker.zip')
    end

    it 'supports custom prefix' do
      custom_uploader = described_class.new(
        bucket: bucket,
        application: application,
        s3_client: mock_s3_client,
        prefix: 'artifacts/deploy'
      )
      key = custom_uploader.generate_key(name: 'worker', content_hash: 'hash99')
      expect(key).to eq('artifacts/deploy/order-service/production/hash99/worker.zip')
    end

    it 'falls back to default app name and stage when application is nil' do
      no_app_uploader = described_class.new(bucket: bucket, s3_client: mock_s3_client)
      key = no_app_uploader.generate_key(name: 'fn1', content_hash: '123')
      expect(key).to eq('veltrunode/app/dev/123/fn1.zip')
    end

    it 'raises ArgumentError when content_hash is missing or blank' do
      expect { uploader.generate_key(name: 'fn', content_hash: '') }
        .to raise_error(ArgumentError, /Content hash must be provided/)
    end

    it 'raises ArgumentError when name is missing or blank' do
      expect { uploader.generate_key(name: '', content_hash: 'hash') }
        .to raise_error(ArgumentError, /Artifact name must be provided/)
    end
  end

  describe '#upload_file' do
    let(:tmpdir) { Dir.mktmpdir }
    let(:zip_file) do
      path = File.join(tmpdir, 'app.zip')
      File.write(path, 'dummy zip content')
      path
    end

    after do
      FileUtils.rm_rf(tmpdir)
    end

    context 'when the artifact does not exist in S3' do
      before do
        not_found_err = StandardError.new('404 Not Found')
        allow(mock_s3_client).to receive(:head_object).and_raise(not_found_err)
        allow(mock_s3_client).to receive(:put_object)
      end

      it 'uploads the file to S3 and returns uploaded status' do
        result = uploader.upload_file(
          file_path: zip_file,
          name: 'worker',
          content_hash: 'hash123'
        )

        expect(result.status).to eq(:uploaded)
        expect(result.uploaded?).to be true
        expect(result.skipped?).to be false
        expect(result.key).to eq('veltrunode/order-service/production/hash123/worker.zip')

        expect(mock_s3_client).to have_received(:put_object).with(
          bucket: bucket,
          key: 'veltrunode/order-service/production/hash123/worker.zip',
          body: an_instance_of(File)
        )
      end
    end

    context 'when the artifact with the same hash already exists in S3' do
      before do
        allow(mock_s3_client).to receive(:head_object).and_return(double('HeadObjectOutput'))
        allow(mock_s3_client).to receive(:put_object)
      end

      it 'skips the upload and does not call put_object' do
        result = uploader.upload_file(
          file_path: zip_file,
          name: 'worker',
          content_hash: 'existing_hash'
        )

        expect(result.status).to eq(:skipped)
        expect(result.skipped?).to be true
        expect(result.uploaded?).to be false
        expect(mock_s3_client).not_to have_received(:put_object)
      end
    end

    context 'when artifact file does not exist on disk' do
      it 'raises S3UploadError with clear message' do
        missing_file = File.join(tmpdir, 'non_existent.zip')
        expect do
          uploader.upload_file(file_path: missing_file, name: 'worker', content_hash: '123')
        end.to raise_error(Veltrunode::AWS::S3UploadError, /Artifact file .* does not exist/)
      end
    end

    context 'when S3 returns NoSuchBucket' do
      before do
        bucket_err = StandardError.new('The specified bucket does not exist (NoSuchBucket)')
        allow(mock_s3_client).to receive(:head_object).and_raise(bucket_err)
      end

      it 'raises S3UploadError explaining bucket does not exist' do
        expect do
          uploader.upload_file(file_path: zip_file, name: 'worker', content_hash: '123')
        end.to raise_error(Veltrunode::AWS::S3UploadError, /S3 bucket 'my-deployment-bucket' does not exist/)
      end
    end

    context 'when S3 returns AccessDenied' do
      before do
        access_err = StandardError.new('Access Denied (AccessDenied)')
        allow(mock_s3_client).to receive(:head_object).and_raise(access_err)
      end

      it 'raises S3UploadError explaining permission issues' do
        expect do
          uploader.upload_file(file_path: zip_file, name: 'worker', content_hash: '123')
        end.to raise_error(Veltrunode::AWS::S3UploadError, /Access denied to S3 bucket 'my-deployment-bucket'/)
      end
    end
  end

  describe '#update_template' do
    let(:sample_template) do
      {
        'AWSTemplateFormatVersion' => '2010-09-09',
        'Resources' => {
          'WorkerFunction' => {
            'Type' => 'AWS::Lambda::Function',
            'Properties' => {
              'FunctionName' => 'worker',
              'Code' => {
                'S3Bucket' => { 'Ref' => 'ArtifactBucket' },
                'S3Key' => 'artifacts/functions/worker.zip'
              }
            }
          },
          'SharedDepsLayerVersion' => {
            'Type' => 'AWS::Lambda::LayerVersion',
            'Properties' => {
              'Content' => {
                'S3Bucket' => { 'Ref' => 'ArtifactBucket' },
                'S3Key' => 'artifacts/layers/shared_deps.zip'
              }
            }
          }
        }
      }
    end

    let(:upload_results) do
      [
        Veltrunode::AWS::UploadResult.new(
          name: 'worker',
          bucket: bucket,
          key: 'veltrunode/order-service/production/hash1/worker.zip',
          status: :uploaded,
          content_hash: 'hash1',
          zip_path: '/path/to/worker.zip',
          type: :function
        ),
        Veltrunode::AWS::UploadResult.new(
          name: 'shared_deps',
          bucket: bucket,
          key: 'veltrunode/order-service/production/hash2/shared_deps.zip',
          status: :uploaded,
          content_hash: 'hash2',
          zip_path: '/path/to/shared_deps.zip',
          type: :layer
        )
      ]
    end

    it 'updates Code.S3Bucket/S3Key for functions and Content.S3Bucket/S3Key for layers' do
      updated = uploader.update_template(sample_template, upload_results: upload_results)

      fn_code = updated['Resources']['WorkerFunction']['Properties']['Code']
      expect(fn_code).to eq({
                              'S3Bucket' => bucket,
                              'S3Key' => 'veltrunode/order-service/production/hash1/worker.zip'
                            })

      layer_content = updated['Resources']['SharedDepsLayerVersion']['Properties']['Content']
      expect(layer_content).to eq({
                                    'S3Bucket' => bucket,
                                    'S3Key' => 'veltrunode/order-service/production/hash2/shared_deps.zip'
                                  })
    end

    it 'updates template file on disk when file path is given' do
      Dir.mktmpdir do |tmpdir|
        tpl_path = File.join(tmpdir, 'template.yml')
        File.write(tpl_path, YAML.dump(sample_template))

        uploader.update_template(tpl_path, upload_results: upload_results)

        saved = YAML.safe_load_file(tpl_path)
        expect(saved['Resources']['WorkerFunction']['Properties']['Code']['S3Key'])
          .to eq('veltrunode/order-service/production/hash1/worker.zip')
      end
    end
  end

  describe '#upload_build_result and #upload_and_update_template' do
    let(:tmpdir) { Dir.mktmpdir }
    let(:fn_zip) do
      p = File.join(tmpdir, 'fn.zip')
      File.write(p, 'fn content')
      p
    end
    let(:layer_zip) do
      p = File.join(tmpdir, 'layer.zip')
      File.write(p, 'layer content')
      p
    end
    let(:tpl_file) do
      p = File.join(tmpdir, 'template.yml')
      template = {
        'Resources' => {
          'ProcessorFunction' => {
            'Type' => 'AWS::Lambda::Function',
            'Properties' => { 'Code' => {} }
          }
        }
      }
      File.write(p, YAML.dump(template))
      p
    end

    let(:fn_res) do
      Veltrunode::Build::PackageResult.new(
        function_name: 'processor',
        zip_path: fn_zip,
        sha256: 'fnsha',
        content_hash: 'fnhash',
        bytesize: 100,
        entries: ['app.rb']
      )
    end
    let(:layer_res) do
      Veltrunode::Build::LayerPackageResult.new(
        layer_name: 'runtime_layer',
        zip_path: layer_zip,
        sha256: 'layersha',
        content_hash: 'layerhash',
        compressed_size: 200,
        uncompressed_size: 400,
        size_diagnostics: {},
        entries: ['bin']
      )
    end
    let(:build_result) do
      Veltrunode::Build::BuildResult.new(
        application: application,
        function_results: [fn_res],
        layer_results: [layer_res],
        template_path: tpl_file,
        template_data: YAML.safe_load_file(tpl_file),
        manifest_path: File.join(tmpdir, 'manifest.json'),
        manifest_data: {}
      )
    end

    after do
      FileUtils.rm_rf(tmpdir)
    end

    it 'uploads all build artifacts and updates template file' do
      not_found_err = StandardError.new('404 Not Found')
      allow(mock_s3_client).to receive(:head_object).and_raise(not_found_err)
      allow(mock_s3_client).to receive(:put_object)

      res = uploader.upload_and_update_template(build_result)

      expect(res[:upload_results].size).to eq(2)
      expect(res[:upload_results].map(&:name)).to contain_exactly('processor', 'runtime_layer')
      expect(res[:template]['Resources']['ProcessorFunction']['Properties']['Code']['S3Key'])
        .to eq('veltrunode/order-service/production/fnhash/processor.zip')
    end
  end
end
