input_params = [10033926071]
input_params = input_params.map(&:to_s).uniq

result = input_params.each_with_object({ complete_cases: [], incomplete_cases: [] }) do |contract_number, acc|
  puts "********* whose turn: #{contract_number} *********"

  contract = Domain::Contract::Model::Contract
               .where(contract_number: contract_number)
               .order(created_at: :desc)
               .first

  next unless contract

  units = Array.wrap(contract.contract_property&.units) # safe if nil

  units.each do |unit|
    unit_services = unit.contract_unit&.contract_unit_services
    electricity_unit_service =
      if unit_services.respond_to?(:find_by)
        unit_services.find_by(utility_service_type: "electricity")
      else
        nil
      end

    attrs = {
      contract_number:  contract_number,
      unit_number:      unit.unit_number,
      premise_id:       electricity_unit_service&.electricity_premise_id,
      electricity_meter: (unit.utilities || {})["electricity_meter"],
      account_no:       electricity_unit_service&.account_no
    }

    # present? is Rails; treats nil/"" as not present
    if attrs.values.all?(&:present?)
      acc[:complete_cases]   << attrs
    else
      acc[:incomplete_cases] << attrs
    end
  end
end

puts "CASES WITH COMPLETE REQUIREMENTS START"
puts JSON.pretty_generate(result[:complete_cases])
puts "CASES WITH COMPLETE REQUIREMENTS END"

puts "CASES WITH INCOMPLETE REQUIREMENTS START"
puts JSON.pretty_generate(result[:incomplete_cases])
puts "CASES WITH INCOMPLETE REQUIREMENTS END"
