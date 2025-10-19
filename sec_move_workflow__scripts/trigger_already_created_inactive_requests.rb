# SEC
namespace :custom_tasks do
  desc "Execute my custom script to check move-in eligibility"
  task ES_1992_trigger_already_created_inactive_requests: :environment do
    EFrame.db_adapter.with_client do
      contract_repository = App::Model::ContractRepository.new(EFrame::Iam.system_context)
      request_repository = App::Model::SecRequestRepository.new(EFrame::Iam.system_context)
      external_call_repository = App::Model::ExternalCallRepository.new(EFrame::Iam.system_context)
      sec_service = App::Services::SecRequestService.new(EFrame::Iam.system_context)
      
      # List of contract numbers to process
      input_params = [10033926071]
      input_params = input_params.map(&:to_s)

      done_cases = []
      undone_cases = []
      
      input_params.each do |contract_number|
        puts "********* Processing contract: #{contract_number} *********"

        sec_requests = request_repository.index(
          filters: {
            contract_number: contract_number,
            request_type: 'move_in',
            status__in: ['pending', 'to_be_transferred', 'waiting_parties']
          },
          page: 1,
          items_per_page: 10,
          sort: { created_at: -1 }
        )

        puts "sec_requests: #{sec_requests.count}"
        
        sec_requests.each do |sec_request|
          approved_request = request_repository.find_by({
            contract_number: contract_number,
            unit_number: sec_request.unit_number,
            premise_id: sec_request.premise_id,
            request_type: 'move_in',
            status__in: ['approved', 'transferred']
          })

          if approved_request.present? && approved_request.sec_reference_number.present?
            request_repository.update!(
              sec_request.id,
              { status: 'canceled', updated_at: Time.current}
            )

            next
          end

          if approved_request.blank?
            if sec_request.sec_reference_number.blank? && ['approved', 'transferred', 'to_be_transferred'].exclude?(sec_request.status)
              request_repository.update!(sec_request._id, {
                status: 'to_be_transferred',
                updated_at: Time.current
              })
              puts "Updated request #{sec_request.request_number} to to_be_transferred status"
              
              # Reload the request to get the updated status
              sec_request = request_repository.find_by!({ _id: sec_request._id })
            end
          end

          # Validate the move-in request
          begin
            App::Services::Validation::MoveInValidation.validate(
              request_number: sec_request.request_number
            )
          rescue => e
            puts "Validation failed for #{sec_request.request_number}: #{e.message}"
            undone_cases.push("#{contract_number}: Validation failed for the unit_number #{unit_number}, #{e.message}")
            next
          end

          contract = contract_repository.find_by({contract_number: contract_number})  

          # Use send to call the private method
          move_in_response, move_in_call_id = sec_service.send(:send_move_in_request_to_sec, sec_request, contract)

          if move_in_call_id.blank? || move_in_response.dig('EJARMoveInResponse', 'ReferenceNumber').blank?
            puts "Failed to get move_in response for #{sec_request.request_number}"
            undone_cases.push("#{contract_number}: MI request #{sec_request.request_number} failed to get successfull response for the unit_number #{unit_number}")
            next
          end

          # Update the request status
          request_repository.update!(sec_request._id, {
            status: 'transferred',
            move_in_call_id: move_in_call_id,
            sec_reference_number: move_in_response.dig('EJARMoveInResponse', 'ReferenceNumber'),
            updated_at: Time.current,
            approved_at: Time.current,
            move_in_date: Time.current,
            sec_status: 'Completed'
          })

          done_cases.push("#{contract_number}: MI request #{sec_request.request_number} is processed successfully for the unit_number #{sec_request.unit_number}")

          # If reflect_meter_number_to_core is also private
          sec_service.send(:reflect_meter_number_to_core, sec_request: sec_request, target: 'contract')
        end
      end

      puts "TRIGGERED ALREADY-CREATED REQUESTS SUCCESS CASES START"
      pp done_cases.join("\n")
      puts "TRIGGERED ALREADY-CREATED REQUESTS SUCCESS CASES END"

      puts "TRIGGERED ALREADY-CREATED REQUESTS FAILED CASES START"
      pp undone_cases.join("\n")
      puts "TRIGGERED ALREADY-CREATED REQUESTS FAILED CASES END"
    end; 0
  end
end; 0