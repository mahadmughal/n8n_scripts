input_params = [2409214098485,2409229494112,2409103627236,2409239390272]

result = []

input_params.each do |invoice_number|
  invoice_details = Infra::Services::Azm::InvoiceService.get_invoice(internal_invoice_no: invoice_number)

  result.push(
    {
      contract_id: invoice_details['oivanContractId'],
      invoice_number: invoice_number.to_s,
      lessor_id_number: invoice_details['beneficiaryFrom'],
      tenant_id_number: invoice_details['beneficiaryTo'],
    }
  )
end

puts "result START"
STDOUT.write(JSON.generate(result))   # compact, one line
puts "result END"