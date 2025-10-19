input_params = [10033926071,30132814177,30079603891,30079603926,30080064331,30079603917,30132814186,30132811228,30132811237,30132811246,30132811255,30132811273,30132811282,30132811291,30080064350]

input_params = input_params.map(&:to_s)

result = input_params.each_with_object([]) do |contract_number, acc|
  contract = Domain::Contract::Model::Contract
               .where(contract_number: contract_number)
               .order(created_at: :desc)
               .first

  next unless contract

  acc << {
    id:               contract.id,
    contract_number:  contract.contract_number.to_s,
    state:            contract.state.to_s
  }
end

puts "CONTRACT IDS START"
puts JSON.pretty_generate(result)   # or JSON.generate(result) for single-line
puts "CONTRACT IDS END"
