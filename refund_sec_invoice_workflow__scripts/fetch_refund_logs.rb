# lib/tasks/es_1111.rake
require 'json'

namespace :custom_tasks do
  desc 'ES_7251'
  task ES_7251: :environment do
    EFrame.db_adapter.with_client do

      input_params = []

      # helper
      def safe_json(raw)
        return {} if raw.nil? || raw == ''
        return raw if raw.is_a?(Hash)
        JSON.parse(raw) rescue {}
      end

      repo = ExternalCalls::Model::CallRepository.new(EFrame::Iam.system_context)

      calls = repo.index(
        filters: {
          'method' => 'Azm.Invoices.Refund',
          'response.body' => /"success"\s*:\s*false/i,
          'created_at__gte' => 2.days.ago
        }
      )

      # arrays to collect invoice_nos
      e0000145_invoices = []
      e0000147_invoices = []
      e000002_invoices  = []
      unknown_invoices  = []

      puts "External calls count: #{calls.count}"

      calls.each do |call|
        invoice_no    = call.fields.dig(:parameters, 'invoiceNo')
        beneficiaries = call.fields.dig(:parameters, 'beneficiaries') || []
        body_raw      = call.fields.dig(:response, :body)
        body          = safe_json(body_raw)
        code          = body['internalCode'] || body.dig('status', 'internalCode')
        message       = body['message']      || body.dig('status', 'message')

        unless code
          puts "[SKIP] invoice=#{invoice_no} — no internalCode in response"
          next
        end

        puts "[CASE] invoice=#{invoice_no} code=#{code} msg='#{message}'"

        case code
        when 'E0000145' # The invoice must be in closed status
          # puts "  → Would retry refund for invoice=#{invoice_no} once it’s CLOSED, with beneficiaries=#{beneficiaries}"
          e0000145_invoices << invoice_no
        when 'E0000147' # The beneficiaries must be related to the invoice
          # puts "  → Would reconcile beneficiaries and retry refund for invoice=#{invoice_no}, given: #{beneficiaries}"
          e0000147_invoices << invoice_no
        when 'E000002'  # Internal Error (HTTP 500)
          # puts "  → Would retry refund for invoice=#{invoice_no} with backoff, beneficiaries=#{beneficiaries}"
          e000002_invoices << invoice_no
        else
          # puts "  → Unknown internalCode=#{code}, invoice=#{invoice_no} — would flag for manual review"
          unknown_invoices << invoice_no
        end
      end

      puts "E0000145 START"
      puts e0000145_invoices.join("\n")
      puts "E0000145 END"

      puts "E0000147 START"
      puts e0000147_invoices.join("\n")
      puts "E0000147 END"

      puts "E000002 START"
      puts e000002_invoices.join("\n")
      puts "E000002 END"

      puts "Unknown START"
      puts unknown_invoices.join("\n")
      puts "Unknown END"

      # print summary
      # puts "\n=== Summary ==="
      # puts "E0000145 (must be closed): #{e0000145_invoices.size} → #{e0000145_invoices.inspect}"
      # puts "E0000147 (beneficiaries mismatch): #{e0000147_invoices.size} → #{e0000147_invoices.inspect}"
      # puts "E000002  (internal error): #{e000002_invoices.size} → #{e000002_invoices.inspect}"
      # puts "Unknown codes: #{unknown_invoices.size} → #{unknown_invoices.inspect}"
    end
  end
end
