input_params = [
  {:idNumber=>'1079841845', :iban=>'SA3480000265608010063113'},
  {:idNumber=>'1024062307', :iban=>'SA0710000027900001176610'},
  {:idNumber=>'7050970735', :iban=>'SA0710000027900001176610'},
]

result = []
done_cases = []
undone_cases = []

input_params.each_slice(2) do |iban_slice|
  response = Infra::Services::Azm::IbanValidationService.check_iban_validation(iban_data: iban_slice)

  puts "************* Response *************"
  pp response

  response["ibans"].each do |record|
    iban = record["iban"]
    id_number = record["accountId"]

    begin
      if record["status"] == "SUCCESS"
        user = Domain::User::Model::IndividualUser.find_by(id_number: id_number)
        entity = Domain::Entity::Model::IndividualEntity.find(user.user_for_id)
        entity_iban = entity.ibans.find_by(iban_number: iban)

        if entity_iban.present?
          entity_iban.verified = true
          entity_iban.legal = true
          entity_iban.save(validate: false)
          done_cases.push("IBAN #{iban} validation passed for #{id_number} so updated successfully")
        else
          undone_cases.push("Investigation need against #{id_number} | #{iban}")
        end
      else
        user = Domain::User::Model::IndividualUser.find_by(id_number: id_number)
        entity = Domain::Entity::Model::IndividualEntity.find(user.user_for_id)
        entity_iban = entity.ibans.find_by(iban_number: iban)
        if entity_iban.present?
          entity_iban.verified = false
          entity_iban.save(validate: false)
          done_cases.push("IBAN #{iban} validation failed for #{id_number}: #{record["message"]}")
        else
          undone_cases.push("Investigation need against #{id_number} | #{iban}")
        end
      end
    rescue => e
      undone_cases.push("Investigation need against #{id_number} | #{iban}")
    end
  end
end

result = done_cases + undone_cases
puts "JIRA COMMENT START"
puts result.join("\n")
puts "JIRA COMMENT END"
puts "TICKET RESOLUTION: #{undone_cases.empty? ? 'Need Confirmation' : 'In Progress'}"

