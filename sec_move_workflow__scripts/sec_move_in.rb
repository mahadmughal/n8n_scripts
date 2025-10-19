# SEC
namespace :custom_tasks do
  desc "Create and trigger move_in requests"
  task ES_1992_sec_move_in: :environment do
    EFrame.db_adapter.with_client do
      contract_repository = App::Model::ContractRepository.new(EFrame::Iam.system_context)
      request_repository = App::Model::SecRequestRepository.new(EFrame::Iam.system_context)
      external_call_repository = App::Model::ExternalCallRepository.new(EFrame::Iam.system_context)
      sec_service = App::Services::SecRequestService.new(EFrame::Iam.system_context)
      
      # List of contract numbers to process
      input_params = [{'contract_number':'10033926071','unit_number':'2','premise_id':'4012080577','electricity_meter':'ECC2420842048014','account_no':'30132811291'}]

      done_cases = []
      undone_cases = []
      
      input_params.each do |params|
        puts "********* Processing contract: #{params[:contract_number]} *********"

        contract_number = params[:contract_number]
        premise_id = params[:premise_id]
        electricity_meter_number = params[:electricity_meter]
        unit_number = params[:unit_number]
        account_no = params[:account_no]
        
        puts "********* Processing unit: #{unit_number} *********"

        begin 
          params = {
            data: {
              attributes: {
                contract_number: contract_number,
                premise_id: premise_id,
                electricity_current_reading: electricity_meter_number,
                meter_reading_date: Time.current,
                unit_number: unit_number,
                account_no: account_no
              }
            }
          }

          puts "Before finding processed MI request"

          sec_request = request_repository.find_by({
            contract_number: contract_number,
            unit_number: unit_number,
            premise_id: premise_id,
            request_type: 'move_in',
            status__in: ['approved', 'transferred']
          })

          puts "After finding processed MI request"

          if sec_request.present? && sec_request.sec_reference_number.present?
            done_cases.push("#{contract_number}: MI request #{sec_request.request_number} is processed successfully for the unit_number #{sec_request.unit_number}")
            next
          end

          # check if move_in request already exists to trigger ...
          sec_request = request_repository.find_by({
            contract_number: contract_number,
            unit_number: unit_number,
            premise_id: premise_id,
            request_type: 'move_in',
            status__in: ['pending', 'to_be_transferred', 'waiting_parties']
          })

          if sec_request.blank?
            # Call the service to check move-in eligibility
            sec_request = sec_service.check_mi_eligible(params: params)
            pp sec_request

            puts "Newly-created request: #{sec_request.request_number}"
          end

          if sec_request.sec_reference_number.present?
            done_cases.push("#{contract_number}: MI request #{sec_request.request_number} is processed successfully for the unit_number #{sec_request.unit_number}")
            next
          end

          if sec_request.sec_reference_number.blank? && ['approved', 'transferred', 'to_be_transferred'].exclude?(sec_request.status)
            request_repository.update!(sec_request._id, {
              status: 'to_be_transferred',
              updated_at: Time.current
            })
            puts "Updated request #{sec_request.request_number} to to_be_transferred status"
            
            # Reload the request to get the updated status
            sec_request = request_repository.find_by!({ _id: sec_request._id })
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
        rescue StandardError => e
          pp "Error processing contract #{contract_number}: #{e.message}"
          undone_cases.push("#{contract_number}: Failed to process MI request due to error: #{e.message}")
        end
      end

      puts "DONE CASES START"
      pp done_cases.join("\n")
      puts "DONE CASES END"

      puts "UNDONE CASES START"
      pp undone_cases.join("\n")
      puts "UNDONE CASES END"
    end; 0
  end
end; 0