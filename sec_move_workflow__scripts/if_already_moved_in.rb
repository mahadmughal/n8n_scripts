# SEC
namespace :custom_tasks do
  desc "Execute my custom script to check move-in eligibility"
  task ES_1992_if_already_moved_in: :environment do
    EFrame.db_adapter.with_client do
      contract_repository = App::Model::ContractRepository.new(EFrame::Iam.system_context)
      request_repository = App::Model::SecRequestRepository.new(EFrame::Iam.system_context)
      external_call_repository = App::Model::ExternalCallRepository.new(EFrame::Iam.system_context)
      sec_service = App::Services::SecRequestService.new(EFrame::Iam.system_context)
      
      # List of contract numbers to process
      input_params = [{'id':'3d4a69cb-bc18-473b-baf9-2f305ce15eed','contract_number':'20894554755','state':'archived'}]
      input_params = input_params.map { |h| h.transform_keys(&:to_sym) }

      already_moved_in_cases = []
      not_moved_in_cases = []

      input_params.each do |params|
        contract_id = params[:id]
        contract_number = params[:contract_number]
        state = params[:state]

        puts "********* Processing contract: #{contract_number} *********"

        sec_requests = request_repository.index(filters: {
                contract_id: contract_id,
                request_type: 'move_in',
                status__in: [
                  'approved',
                  'transferred',
                ]
              })

        if sec_requests.count > 0
          # TODO: cover this case related to multiple units.
          already_moved_in_cases << "#{contract_number}: The tenant is already moved in."
        else
          not_moved_in_cases << "#{contract_number}: The contract is #{state} so MI not applicable."
        end
      end

      puts "ALREADY MOVED IN CASES START"
      pp already_moved_in_cases.join("\n")
      puts "ALREADY MOVED IN CASES END"

      puts "NOT MOVED IN CASES START"
      pp not_moved_in_cases.join("\n")
      puts "NOT MOVED IN CASES END"
    end; 0
  end
end; 0