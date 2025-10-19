#SEC
namespace :custom_tasks do
  desc "Execute my custom script"
  task ES_1992_sec_move_out: :environment do
    EFrame.db_adapter.with_client do
      request_repository = App::Model::SecRequestRepository.new(EFrame::Iam.system_context)
      sec_service = App::Services::SecRequestService.new(EFrame::Iam.system_context)
      contract_repository = App::Model::ContractRepository.new(EFrame::Iam.system_context)
      external_call_repository = App::Model::ExternalCallRepository.new(EFrame::Iam.system_context)
      
      SEC_REQUEST_STATUS = App::Model::SecRequestRepository::STATUS

      done_cases = []
      undone_cases = []
      mo_requests_with_error_message = []

      input_params = [10209440421,10821688655,10590822617]
      input_params = input_params.map(&:to_s)

      input_params.each do |contract_number|
        begin
          contract = contract_repository.find_by({contract_number: contract_number})
          contract_id = contract&.id

          if contract.present?
            puts "********* whose turn: #{contract_number} *********"
          else
            done_cases.push("#{contract_number}: contract is terminated/expired/archived/rejected so system unable to process move out request as there's no MI request.")
            next
          end

          mi_requests = request_repository.index(
              filters: {
                contract_number: contract_number,
                request_type: 'move_in',
                status__in: [
                  SEC_REQUEST_STATUS[:to_be_transferred],
                  SEC_REQUEST_STATUS[:approved],
                  SEC_REQUEST_STATUS[:transferred],
                  SEC_REQUEST_STATUS[:pending],
                  SEC_REQUEST_STATUS[:waiting_parties]
                ]
              },
              page: 1,
              items_per_page: 20,
              sort: { created_at: -1 }
          )

          if mi_requests.size > 0
            mi_requests.each do |mi_request|
              if mi_request.move_in_date&.to_date == Date.current
                undone_cases.push("#{contract_number}: MI and MO request cannot be processed on the same day.")
                next
              end

              case mi_request.status
              when SEC_REQUEST_STATUS[:to_be_transferred], SEC_REQUEST_STATUS[:pending], SEC_REQUEST_STATUS[:waiting_parties]
                request_repository.no_event do
                  request_repository.update!(mi_request._id, {
                    status: SEC_REQUEST_STATUS[:canceled],
                    updated_at: Time.current
                  })
                end
              when SEC_REQUEST_STATUS[:approved], SEC_REQUEST_STATUS[:transferred]
                approved_mo = request_repository.find_by({
                    premise_id: mi_request.premise_id,
                    request_type: 'move_out',
                    contract_id: mi_request.contract_id,
                    unit_number: mi_request.unit_number,
                    status__in: ::App::Model::SecRequestRepository::ACTIVE_STATUSES
                })

                if approved_mo.present?
                  done_cases.push("#{contract_number}: MO request #{approved_mo.request_number} is processed successfully for the unit_number #{approved_mo.unit_number}")
                  next
                else
                  mo_request = nil

                  pending_mo_requests = request_repository.index(
                    filters: {
                      contract_id: contract_id,
                      unit_number: mi_request.unit_number,
                      premise_id: mi_request.premise_id,
                      request_type: 'move_out',
                      status__in: ['pending', 'waiting_parties']
                    },
                    page: 1,
                    items_per_page: 100,
                    sort: { created_at: -1 }
                  )

                  if pending_mo_requests.size == 0
                    # no pending MO requests. Need to create a MO request to trigger it.
                    params = {
                      event: {
                        resource_id: contract_id,
                      }
                    }

                    begin
                      ::App::Services::Validation::MoveOutValidation.validate(
                        mi_request: mi_request,
                        mo_date: Date.current
                      )
                    rescue => e
                      undone_cases.push("#{contract_number}: Move out validation failed for the unit_number #{mi_request.unit_number}, #{e.message}")
                      next
                    end

                    request_obj = {
                      request_type: "move_out",
                      status: SEC_REQUEST_STATUS[:pending],
                      request_date: Date.current.strftime('%Y-%m-%d'),
                      move_out_date: Date.current.strftime('%Y-%m-%d'),
                      meter_reading_date: Date.current.strftime('%Y-%m-%d'),
                      electricity_current_reading: nil,
                      move_in_request_id: mi_request.id.to_s,
                      created_by: 'system',
                      updated_at: Time.current,
                      created_at: Time.current,
                      sec_status: ::App::Model::SecRequestRepository::SEC_STATUSES['in_progress']
                    }

                    common_data = mi_request.fields.slice(
                      :contract_id,
                      :contract_unit_service_id,
                      :premise_id,
                      :site_scenario,
                      :equipment_number,
                      :meter_number,
                      :meter_type,
                      :contract_number,
                      :tenant_pay_outstanding,
                      :move_in_date,
                      :unit_number,
                      :contract_change_history,
                      :notification_number,
                      :account_no
                    )

                    request_obj.merge!(common_data)

                    if request_obj[:account_no].present?
                      params = { ContractAccount: request_obj[:account_no] }
                      external_call = ExternalCalls.service.call(
                        "SEC.AccountCheck",
                        params: params,
                        priority: ExternalCalls::Model::Call::PRIORITY_SYNC
                      )

                      account_check_call_id = external_call._id.is_a?(String) ? external_call._id : external_call._id["$oid"]
                      payload = external_call&.payload
                      account_check_response = payload.dig('Body', 'EJARAccountCheckResponse')

                      if account_check_call_id.present? &&
                        account_check_response.present?
                        request_obj[:account_check_call_id] = account_check_call_id
                        request_obj[:meter_number] = account_check_response.dig('EJARAccountCheck', 'MeterDetails', 'MeterNumber').to_s.strip
                        request_obj[:site_scenario] = account_check_response.dig('EJARAccountCheck', 'SiteScenario').to_s.strip
                        request_obj[:equipment_number] = account_check_response.dig('EJARAccountCheck', 'MeterDetails', 'EquipmentNumber').to_s.strip
                        # request_obj[:meter_type] = !dumb?(account_check_response) ? 'smart_meter' : 'dumb_meter'
                        request_obj[:premise_outstanding_balance] = account_check_response.dig("EJARAccountCheck", "OutstandingBalanceofPremise").to_s.strip
              
                        if account_check_response.dig("EJARAccountCheck", "ProposedMeterRead").to_i > 0
                          request_obj[:proposed_meter_reading] = account_check_response.dig("EJARAccountCheck", "ProposedMeterRead")
                        end
                      end
                    end

                    request_obj.merge!(request_number: App::Utils::Token.unique_human_readable_token)

                    id = request_repository.create(request_obj)
                    
                    newly_created_mo_request = request_repository.find_by!({ _id: BSON::ObjectId(id) })
                    
                    if newly_created_mo_request.present?
                      begin
                        response, call_id = ::App::Services::MoveOutRequest::Send.new(EFrame::Iam.system_context).call(newly_created_mo_request, contract)
                      rescue => e
                        mo_request = request_repository.find_by!({ _id: BSON::ObjectId(id) })
                        undone_cases.push("#{contract_number}: MO request is triggered but failed for the unit_number #{mi_request.unit_number}, due to the error: #{mo_request.message_error["en"]}")
                        mo_requests_with_error_message.push(newly_created_mo_request.request_number)
                        next
                      end

                      if call_id.present?
                        done_cases.push("#{contract_number}: MO request is processed successfully for the unit_number #{mi_request.unit_number}")
                      else
                        mo_request = request_repository.find_by!({ _id: BSON::ObjectId(id) })
                        undone_cases.push("#{contract_number}: MO request is triggered but failed for the unit_number #{mi_request.unit_number}, due to the error: #{mo_request.message_error["en"]}")
                        mo_requests_with_error_message.push(newly_created_mo_request.request_number)
                      end
                    else
                      undone_cases.push("#{contract_number}: MO request is not created successfully for the unit_number #{mi_request.unit_number}, need investigation in this case.")
                    end
                  else
                    pending_mo_requests.each_with_index do |r, i|
                      if i == 0
                        mo_request_to_trigger = r
                      else
                        request_repository.update!(r._id, {
                          status: 'canceled',
                          updated_at: Time.current
                        })
                      end
                    end

                    begin
                      response, call_id = ::App::Services::MoveOutRequest::Send.new(EFrame::Iam.system_context).call(mo_request_to_trigger, contract)
                    rescue => e
                      mo_request = request_repository.find_by!({ request_number: mo_request_to_trigger.request_number })
                      undone_cases.push("#{contract_number}: MO request is triggered but failed for the unit_number #{mi_request.unit_number}, due to the error: #{mo_request_to_trigger.message_error["en"]}")
                      mo_requests_with_error_message.push(mo_request_to_trigger.request_number)
                      next
                    end

                    if call_id.present?
                      done_cases.push("#{contract_number}: MO request is processed successfully for the unit_number #{mi_request.unit_number}")
                    else
                      mo_request = request_repository.find_by!({ _id: BSON::ObjectId(id) })
                      undone_cases.push("#{contract_number}: MO request is triggered but failed for the unit_number #{mi_request.unit_number}, due to the error: #{mo_request.message_error["en"]}")
                      mo_requests_with_error_message.push(mo_request_to_trigger.request_number)
                    end
                  end
                end
              end
            end
          else
            contract = Ejar3::Api.contract.fetch_contract_info(nil, nil, contract_id)

            unless contract
              done_cases.push("#{contract_number}: contract is terminated/expired/archived/rejected so system unable to process move out request as there's no MI request.")
              next
            end

            if contract.present? && ['terminated', 'expired', 'archived', 'rejected'].include?(contract.state)
              done_cases.push("#{contract_number}: contract is terminated/expired/archived/rejected so system unable to process move out request as there's no MI request.")
              next
            else
              done_cases.push("#{contract_number}: contract is terminated/expired/archived/rejected so system unable to process move out request as there's no MI request.")
              next
            end
          end
        rescue => e
          undone_cases.push("#{contract_number}: #{e.message}")
        end
      end

      if mo_requests_with_error_message.present?
        puts "********* MO requests with error message *********"
        
        mo_requests_with_error_message.each do |request_number|
          mo_request = request_repository.find_by!({ request_number: request_number })
          puts "#{request_number}: #{mo_request.message_error["en"]}"
        end
      end

      puts "DONE CASES START"
      pp done_cases.join("\n")
      puts "DONE CASES END"
      
      puts "UNDONE CASES START"
      pp undone_cases.join("\n")
      puts "UNDONE CASES END"

      result = done_cases + undone_cases
      puts "JIRA COMMENT START"
      pp result.join("\n")
      puts "JIRA COMMENT END"
    end
  end
end