namespace :custom_tasks do
  desc "ES_5879_rectify_parties_ids"
  task ES_5879_rectify_parties_ids: :environment do
    repository = App::Model::UnitSecurityFormRepository.new(EFrame::Iam.system_context)

    input_params = [{
    'contract_id': 'eb4cc566-1053-48a0-90ca-467ddd12cbe1',
    'invoice_number': '2409214098485',
    'lessor_id_number': '1112526163',
    'tenant_id_number': '2316826276'
  },
  {
    'contract_id': 'ed99e55d-eab5-44f1-bbf3-1cbbf8ee44a1',
    'invoice_number': '2409229494112',
    'lessor_id_number': '1112526163',
    'tenant_id_number': '1002631420'
  },
  {
    'contract_id': '9d5c2673-d633-436d-81a0-624e93b4e126',
    'invoice_number': '2409103627236',
    'lessor_id_number': '1031002841',
    'tenant_id_number': '2429601749'
  },
  {
    'contract_id': '98574969-bd86-4594-91d1-c4f27b6f82a6',
    'invoice_number': '2409239390272',
    'lessor_id_number': '1023470816',
    'tenant_id_number': '2503491108'
  }]

    rectified_cases = []

    input_params.each do |params|
      invoice_number = params[:invoice_number]
      contract_id = params[:contract_id]
      lessor_id_number = params[:lessor_id_number]
      tenant_id_number = params[:tenant_id_number]

      form = repository.find_by({contract_id: contract_id})

      if form.nil?
        puts "Form not found for invoice number: #{invoice_number} and contract id: #{contract_id}"
        next
      end

      mismatched = form.lessor_id_number != lessor_id_number

      if mismatched
        repository.update!(form.id, {lessor_id_number: lessor_id_number})
        puts "Rectified lessor id: #{form.id}"
        rectified_cases.push(invoice_number)
      else
        puts "Lessor id is already correct"
      end

      if form.nil?
        puts "Form not found for invoice number: #{invoice_number} and contract id: #{contract_id}"
        next
      end

      mismatched = form.tenant_id_number != tenant_id_number

      if mismatched
        repository.update!(form.id, {tenant_id_number: tenant_id_number})
        puts "Rectified tenant id: #{form.id}"
        rectified_cases.push(invoice_number)
      else
        puts "Tenant id is already correct"
      end
    end

    puts "RECTIFIED_CASES START"
    puts rectified_cases.join("\n")
    puts "RECTIFIED_CASES END"
  end
end



