namespace :custom_tasks do
  desc "ES_9376_refund_security_deposit_with_damage_evaluation"
  task ES_9376_refund_security_deposit_with_damage_evaluation: :environment do
    repository = App::Model::UnitSecurityFormRepository.new(EFrame::Iam.system_context)
    unit_security_form_service = App::Services::UnitSecurityFormService.new(EFrame::Iam.system_context)
    inspection_request_repo = App::Model::InspectionRequestRepository.new(EFrame::Iam.system_context)

    input_params = [
      "23f687e8-8126-44c4-b770-b80737e1bf94",
    ]

    done_cases = []
    undone_cases = []

    input_params.each do |contract_id|
      puts "\n[MIMO] Processing contract ID: #{contract_id}"
      
      # Find the form for this contract
      form = repository.find_by({ contract_id: contract_id })
      # form = repository.find_by({ contract_number: contract_id })
      contract_id = form&.contract_id
      contract_number = form&.contract_number

      if form.nil?
        puts "[MIMO] No form found for contract ID: #{contract_id}"
        undone_cases.push(["No form found for contract ID: #{contract_id}"])
        next
      end

      puts "[MIMO] Found form with ID: #{form.id}"
      puts "[MIMO] Current MI status: #{form.mi_status || 'nil'}, MO status: #{form.mo_status || 'nil'}"

      auto_renewal = false
      # skip if form is manual contract cloned form
      if form.previous_form_id
        auto_renewal = repository.find_by({
          id: form.previous_form_id,
          contract_number: form.contract_number
        }).present?

        return unless auto_renewal
      end

      if form.mo_status == 'expired' || form.mo_status == 'done'
        unless form.security_deposit_invoice_number
          puts "[MIMO] No security deposit invoice number found for contract number: #{contract_number}"
          undone_cases.push([form.security_deposit_invoice_number, "No security deposit invoice number found to refund. Parties already responded to MO form"])
          next
        end

        if form.mo_damage_amount_by_lessor.present? || form.mo_damage_amount_by_tenant.present?
          if form.mo_damage_amount_by_lessor != form.mo_damage_amount_by_tenant
            puts "******** Damage amount must be equal *********"
            undone_cases.push([form.security_deposit_invoice_number, "Damage amount must be equal"])
            next
          end
        end

        new_form = repository.find_by({ previous_form_id: form.id })

        if !new_form&.is_archived_form && %w(registered active).include?(form&.contract_state)
          puts "[MIMO] Contract state is registered or active so not refund"
          undone_cases.push([form.security_deposit_invoice_number, "Contract state is registered or active so not refund"])
          next
        end

        inspection_request = inspection_request_repo.find_by({unit_security_form_id: form.id})

        if inspection_request.present? && inspection_request.integration? && inspection_request.closed_completed?
          expert_damage_evaluation = inspection_request.expert_damage_evaluation
          puts "[MIMO] Completed Inspection request found for form ID with damage evaluation: #{expert_damage_evaluation}"
        elsif inspection_request.present?
          puts "[MIMO] Inspection request found for form ID but not closed or completed: #{form.id}"
          undone_cases.push([form.security_deposit_invoice_number, "Inspection request found for form ID but not closed or completed"])
          next
        else
          puts "[MIMO] No inspection request found for form ID: #{form.id}"
          expert_damage_evaluation = nil
        end

        refund_handler = App::Services::RefundService.new(form: form, expert_damage_evaluation: expert_damage_evaluation)
        puts "[MIMO] Expert damage evaluation: #{refund_handler.expert_damage_evaluation}"
        refund_handler.expert_damage_evaluation

        next if refund_handler.expert_damage_evaluation

        puts "[MIMO] Refund amount: #{refund_handler.refund_amount}"
        refund_handler.refund_amount

        refund_call = refund_handler.call

        if refund_call
          App::Services::SmsService.new(form: form).call
          puts "[MIMO] Refund SMS sent for contract number: #{contract_number}"

          done_cases.push(form.security_deposit_invoice_number)
        end
      end

      Workers::UnitSecurityForms::UpdateCoreContract.perform_in(0.seconds, form.id)

      if !auto_renewal
        Workers::UnitSecurityForms::UpdateCloneForm.perform_in(0.seconds, form.id)
      end
    end

    puts "REFUNDED CASES START"
    pp done_cases.join("\n")
    puts "REFUNDED CASES END"

    puts "UNDONE CASES START"
    pp undone_cases.join("\n")
    puts "UNDONE CASES END"
  end
end