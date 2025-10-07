input_params = []

done_cases = []
undone_cases = []

input_params.each do |invoice_number|
  puts "********************** Invoice_number: #{invoice_number} *************************"
  pp Infra::Services::Azm::InvoiceService.approve_invoice(
    internal_invoice_no: invoice_number
  )
end

input_params.each do |invoice_number|
  puts "********************** Invoice_number: #{invoice_number} *************************"
  status = Infra::Services::Azm::InvoiceService.get_invoice_status_code(internal_invoice_no: invoice_number)

  if status == 'apvd'
    done_cases.push(invoice_number)
  else
    undone_cases.push(invoice_number)
  end
end

puts "APPROVED_INVOICES START"
puts done_cases.join("\n")
puts "APPROVED_INVOICES END"

puts "UNDONE_INVOICES START"
puts undone_cases.join("\n")
puts "UNDONE_INVOICES END"

