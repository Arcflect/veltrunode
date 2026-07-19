# frozen_string_literal: true

require 'json'
require 'spec_helper'

RSpec.describe Veltrunode::Diagnostics::Diagnostic do
  describe 'initialization' do
    it 'stores required and optional attributes' do
      diagnostic = described_class.new(
        code: 'VLT-DSL-001',
        severity: :error,
        summary: 'Invalid function declaration.',
        suggested_action: 'Check the function block syntax.',
        evidence: { line: 12, token: 'function' },
        source_path: 'app/veltrunode.rb',
        aws_resource_id: 'arn:aws:lambda:ap-northeast-1:123456789012:function:hello'
      )

      expect(diagnostic.code).to eq('VLT-DSL-001')
      expect(diagnostic.severity).to eq(:error)
      expect(diagnostic.summary).to eq('Invalid function declaration.')
      expect(diagnostic.suggested_action).to eq('Check the function block syntax.')
      expect(diagnostic.evidence).to eq({ 'line' => 12, 'token' => 'function' })
      expect(diagnostic.source_path).to eq('app/veltrunode.rb')
      expect(diagnostic.aws_resource_id).to eq('arn:aws:lambda:ap-northeast-1:123456789012:function:hello')
    end

    it 'is immutable and deeply freezes evidence' do
      refs = [String.new('db_primary')]
      diagnostic = described_class.new(
        code: 'VLT-REF-001',
        severity: :warning,
        summary: 'Reference could not be resolved.',
        suggested_action: 'Confirm that the target symbol is declared.',
        evidence: { refs: refs }
      )

      expect(refs).not_to be_frozen
      expect(refs.first).not_to be_frozen
      expect(diagnostic).to be_frozen
      expect(diagnostic.evidence).to be_frozen
      expect(diagnostic.evidence['refs']).to be_frozen
      expect { diagnostic.evidence['refs'] << 'db_replica' }.to raise_error(FrozenError)
    end

    it 'rejects invalid diagnostic codes' do
      expect do
        described_class.new(
          code: 'INVALID-001',
          severity: :error,
          summary: 'Bad code format.',
          suggested_action: 'Use VLT-<category>-<id> format.'
        )
      end.to raise_error(ArgumentError, /invalid diagnostic code format/)
    end
  end

  describe '#to_text' do
    it 'renders a clean-room plain text diagnostic message' do
      diagnostic = described_class.new(
        code: 'VLT-EFS-2049-INGRESS',
        severity: :warning,
        summary: 'NFS ingress is not permitted for the selected security group.',
        suggested_action: 'Allow TCP 2049 ingress from the Lambda security group.',
        evidence: { security_group_id: 'sg-12345', port: 2049 },
        source_path: 'infra/app.rb'
      )

      text = diagnostic.to_text
      expected_summary = 'VLT-EFS-2049-INGRESS: '
      expected_summary += 'NFS ingress is not permitted for the selected security group.'

      expect(text).to include(expected_summary)
      expect(text).to include('Severity: warning')
      expect(text).to include('Suggested action: Allow TCP 2049 ingress from the Lambda security group.')
      expect(text).to include('Source path: infra/app.rb')
      expect(text).to include('Evidence:')
      expect(text).to include('security_group_id')
    end
  end

  describe '#to_json' do
    it 'renders a JSON object with all fields' do
      diagnostic = described_class.new(
        code: 'VLT-IAM-001',
        severity: :info,
        summary: 'Policy check completed.',
        suggested_action: 'Review wildcard permissions before deployment.'
      )

      parsed = JSON.parse(diagnostic.to_json)

      expect(parsed['code']).to eq('VLT-IAM-001')
      expect(parsed['severity']).to eq('info')
      expect(parsed['summary']).to eq('Policy check completed.')
      expect(parsed['suggested_action']).to eq('Review wildcard permissions before deployment.')
      expect(parsed['evidence']).to eq({})
      expect(parsed['source_path']).to be_nil
      expect(parsed['aws_resource_id']).to be_nil
    end
  end
end
