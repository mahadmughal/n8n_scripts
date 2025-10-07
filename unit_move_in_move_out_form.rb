namespace :custom_tasks do
  desc "ES_8659_unit_move_in_move_out"
  task ES_8659_unit_move_in_move_out: :environment do
    repository = App::Model::UnitSecurityFormRepository.new(EFrame::Iam.system_context)
    contract_service = App::Services::ContractService.new(EFrame::Iam.system_context)

    input_params = ['1f17c080-b46f-43c8-a189-d8776b56917a','bad2ca7e-8465-480b-bae4-cd2f47c92140']

    first_element = input_params.first
    if first_element.is_a?(String) && first_element.length > 11
      input_params = first_element.split(",")
    end

    puts "input_params: #{input_params}"

    done_cases = []
    undone_cases = []
    undone_manual_renewal_cases = []
    no_invoice_cases = []

    input_params.each do |contract_number|
      contract_number = contract_number.to_s.downcase

      begin
        puts "Processing contract: #{contract_number}"

        forms = if contract_number.to_s.match?(/^\d+$/) # numeric => contract_number
                  repository.index(filters: { contract_number: contract_number.to_s })
                else
                  repository.index(filters: { contract_id: contract_number })
                end

        unless contract_number.to_s.match?(/^\d+$/)
          contract = Ejar3::Api.contract.contract_details(contract_number.to_s, 'e3security')
          contract_number = contract.contract_number
        end

        if forms.present? && forms.count > 0
          form = forms.last
          puts "Form found for contract number: #{contract_number}"

          puts "[MIMO] Current MI status: #{form.mi_status || 'nil'}, MO status: #{form.mo_status || 'nil'}"

          if form.mo_status == 'expired' || form.mo_status == 'done'
            unless form.security_deposit_invoice_number
              if form.mo_tenant_status == 'done' && form.mo_lessor_status == 'done'
                undone_cases.push("#{contract_number}:  No security deposit invoice number found to refund. Parties already responded to MO form")
                no_invoice_cases.push("#{contract_number}:  No security deposit invoice number found to refund. Parties already responded to MO form")
              else
                undone_cases.push("#{contract_number}:  No security deposit invoice number found to refund. Both or either parties unable to respond to MO form so system responded after 7 days and made the form as expired.")
                no_invoice_cases.push("#{contract_number}:  No security deposit invoice number found to refund. Both or either parties unable to respond to MO form so system responded after 7 days and made the form as expired.")
              end
            end

            prev_form = repository.find_by({ previous_form_id: form.id })

            if %w(registered active).include?(form&.contract_state)
              contract_data = contract_service.expose_contract_data(form.contract_id)&.deep_symbolize_keys
              repository.update!(form.id, { contract_state: contract_data[:state] } )
              form = repository.find_by({ id: form.id })

              if %w(registered active).include?(form&.contract_state)
                undone_cases.push("#{contract_number}: Contract state is registered or active so system unable to refund the security deposit amount.")
              end
            end

            if form.mo_damage_amount_by_lessor.present? || form.mo_damage_amount_by_tenant.present?
              done_cases.push("#{contract_number}: Involves damage evaluation. Please confirm the refund action as MO form is responded/expired so amount can be refunded considering damage amount.")
            elsif form.security_deposit_invoice_number.present?
              done_cases.push("#{contract_number}: Please confirm the refund action as MO form is responded/expired so amount can be refunded.")
            end
          elsif form.mo_status == 'created' || (form.mo_status.nil? && %w(expired terminated archived revoked active).include?(form.contract_state)) || (form.mo_status == 'waiting_parties' && form.mo_activated_date.nil?)
            attributes = {
              mo_activated_date: Date.current.strftime('%F'),
              mo_status: 'waiting_parties',
              mo_form_number: "Move-Out-#{contract_number}",
              mo_tenant_status: 'waiting_parties',
              mo_lessor_status: 'waiting_parties',
              mo_editable: true
            }

            attributes.merge!({ mo_created_date: Date.current.strftime('%F') }) if form.mo_created_date.nil?
            repository.update!(form.id, attributes)
            done_cases.push("#{contract_number}: MO form was not available to parties. Now MO form is activated to made available to parties to edit. Please confirm with contract's parties to update the MO form.")
          elsif (form.mo_status == 'waiting_parties' || form.mo_status == 'waiting_lessor' || form.mo_status == 'waiting_tenant') && form.mo_activated_date.present?
            if form.mo_activated_date < (Date.current - 7.days)
              attributes = {
                form_type: "move_out",
                mo_activated_date: Date.current.strftime('%F'),
                mo_status: 'expired',
                mo_form_number: "Move-Out-#{contract_number}",
                mo_tenant_status: 'expired',
                mo_lessor_status: 'expired',
                mo_lessor_answer: 'yes',
                mo_tenant_answer: 'yes',
                mo_editable: false
              }
              repository.update!(form.id, attributes)
              done_cases.push("#{contract_number}: MO form is made expired now as per system logic so please confirm the refund action for this case so amount can be refunded.")
            elsif form.mo_activated_date >= (Date.current - 7.days)
              attributes = {
                mo_activated_date: Date.current.strftime('%F'),
                mo_editable: true,
                mo_lessor_answer: 'yes',
                mo_tenant_answer: 'yes',
              }
              repository.update!(form.id, attributes)
              done_cases.push("#{contract_number}: MO form is still active for contract parties to fill in. Please confirm with contract's parties to update the MO form.")
            end
          end
        else
          undone_cases.push("#{contract_number}: This case needs investigation as it may involve manual-renewal of the contract OR it may not have security deposit form created yet for the contract")
          undone_manual_renewal_cases.push(contract_number)
        end

      rescue => e
        # Capture errors for the contract and continue
        error_message = "#{contract_number}: Failed due to error - #{e.class}: #{e.message}"
        puts error_message
        undone_cases.push(error_message)
      end
    end

    puts "************** Done Cases START **************"
    pp done_cases
    puts "************** Done Cases END **************"

    puts "************** undone Cases START **************"
    puts undone_cases.join("\n")
    puts "************** undone Cases END **************"

    puts "************** No Invoice Cases START **************"
    pp no_invoice_cases
    puts "************** No Invoice Cases END **************"

    puts "************** Undone Manual Renewal Cases START **************"
    pp undone_manual_renewal_cases
    puts "************** Undone Manual Renewal Cases END **************"

    puts "************** Result **************"
    result = undone_cases + done_cases

    puts "JIRA COMMENT START"
    puts result.join("\n")
    puts "JIRA COMMENT END"
  end
end
