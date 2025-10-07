input_params = [2504175743415]

reserved_cases = []
undone_cases = []

input_params.each do |invoice_number|
  puts "********************** Invoice_number: #{invoice_number} *************************"

  begin 
    is_reserved = Infra::Services::Azm::WalletService.has_reserved_amount?(
      internal_invoice_no: invoice_number
    )

    if is_reserved
      reserved_cases.push(invoice_number)
    else
      is_reserved = Infra::Services::Azm::WalletService.reserve_invoice_amount(
              internal_invoice_no: invoice_number
            )

      if is_reserved
        reserved_cases.push(invoice_number)
      else
        undone_cases.push(invoice_number)
      end
    end
  rescue => e
    undone_cases.push(invoice_number)
  end
end

puts "RESERVED_CASES START"
puts reserved_cases.join("\n")
puts "RESERVED_CASES END"

puts "UNDONE_CASES START"
puts undone_cases.join("\n")
puts "UNDONE_CASES END"

