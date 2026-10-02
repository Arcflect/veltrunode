# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

RSpec.describe 'Container build integration test', :integration do
  let(:fixture_dir) { File.expand_path('../fixtures/integration/with_layer', __dir__) }

  before do
    skip 'Docker or Podman is not available in the current environment' unless IntegrationHelper.container_available?
  end

  it 'builds Ruby layer and function inside container and produces valid artifacts' do
    tmpdir = Dir.mktmpdir('veltrunode-container-build-test-')
    begin
      FileUtils.cp_r("#{fixture_dir}/.", tmpdir)

      application = Veltrunode::SettingsLoader.load(file_path: File.join(tmpdir, 'Veltrunodefile'))

      result = Veltrunode::Build::Pipeline.execute(application, source_dir: tmpdir)

      expect(result).to be_a(Veltrunode::Build::BuildResult)
      expect(result.functions_count).to eq(1)
      expect(result.layers_count).to eq(1)

      # 成果物 zip の存在と妥当性を検証
      layer_res = result.layer_results.find { |r| r.layer_name.to_s == 'gem_deps' }
      expect(layer_res).not_to be_nil
      expect(File.exist?(layer_res.zip_path)).to be true
      expect(File.size(layer_res.zip_path)).to be > 0

      # レイヤー zip 内の Ruby ディレクトリ構造を検証
      gem_found = false
      Zip::File.open(layer_res.zip_path) do |zip|
        zip.each do |entry|
          gem_found = true if entry.name.start_with?('ruby/gems/3.3.0/gems/rainbow-')
        end
      end
      expect(gem_found).to be true

      # 関数 zip の存在を検証
      fn_res = result.function_results.find { |r| r.function_name.to_s == 'api' }
      expect(fn_res).not_to be_nil
      expect(File.exist?(fn_res.zip_path)).to be true
      expect(File.size(fn_res.zip_path)).to be > 0
    ensure
      # コンテナ内で root 作成されたファイルの削除権限を回復
      system("chmod -R u+rwX #{tmpdir} 2>/dev/null")
      FileUtils.rm_rf(tmpdir)
    end
  end
end
