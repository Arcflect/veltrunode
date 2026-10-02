# frozen_string_literal: true

require 'json'
require 'time'

def handler(event:, context:)
  file_path = "/mnt/shared/integ_test_#{Time.now.to_i}.txt"
  test_content = event.fetch('content', "Veltrunode EFS integration test content: #{Time.now.utc.iso8601}")

  # 書き込み
  File.write(file_path, test_content)

  # 読み出し
  read_content = File.read(file_path)

  # クリーンアップ
  File.delete(file_path) if File.exist?(file_path)

  {
    statusCode: 200,
    body: JSON.generate({
      written: test_content,
      read: read_content,
      matched: test_content == read_content
    })
  }
end
