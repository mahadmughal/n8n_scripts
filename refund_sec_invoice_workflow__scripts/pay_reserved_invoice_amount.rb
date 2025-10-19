input_params = [2504175743415]

closed_cases = []
undone_cases = []

input_params.each do |invoice_number|
  puts "********************** Invoice_number: #{invoice_number} *************************"

  begin 
    invoice_data = Infra::Services::Azm::InvoiceService.get_invoice(
      internal_invoice_no: invoice_number
    )

    contract_id = invoice_data['oivanContractId']

    contract = Domain::Contract::Model::Contract.find_by(id: contract_id)

    if contract.present?
      WALLET_SERVICE = Infra::Services::Azm::WalletService

      sealing_date = contract&.sealing_at&.in_time_zone("Asia/Riyadh")&.strftime("%Y-%m-%d %H:%M:%S")

      if sealing_date.present?
        WALLET_SERVICE.pay_invoice_reservation(
          internal_invoice_no: invoice_number,
          sealing_date: sealing_date
        )
      else
        undone_cases.push(invoice_number)
      end

      closed_cases.push(invoice_number)
    else
      undone_cases.push(invoice_number)
    end
  rescue => e
    undone_cases.push(invoice_number)
  end
end

puts "CLOSED_CASES START"
puts closed_cases.join("\n")
puts "CLOSED_CASES END"

puts "UNDONE_CASES START"
puts undone_cases.join("\n")
puts "UNDONE_CASES END"
