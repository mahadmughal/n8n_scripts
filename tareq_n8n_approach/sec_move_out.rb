# frozen_string_literal: true

# Usage:
#   result = SecMoveOutOrchestrator.new(contracts: ["10758399889"]).execute
#   puts JSON.pretty_generate(result)


namespace :custom_tasks do
  desc "Execute my custom script"
  task ES_1992_sec_move_out: :environment do
    EFrame.db_adapter.with_client do
      class SecMoveOutOrchestrator
        INACTIVE_CONTRACT_STATES = %w[terminated expired archived rejected].freeze

        # Core state
        attr_reader :contracts, :debug_mode, :execution_log, :all_results

        # Per-item state
        attr_reader :contract_number, :contract, :mi_requests, :request_repository,
                    :contract_repository, :external_call_repository

        def initialize(contracts:, debug_mode: true)
          @contracts = Array(contracts).map(&:to_s)
          @debug_mode = debug_mode
          @execution_log = []
          @all_results = []

          # Repositories
          @request_repository       = App::Model::SecRequestRepository.new(EFrame::Iam.system_context)
          @contract_repository      = App::Model::ContractRepository.new(EFrame::Iam.system_context)
          @external_call_repository = App::Model::ExternalCallRepository.new(EFrame::Iam.system_context)

          @SEC_REQUEST_STATUS = App::Model::SecRequestRepository::STATUS
          @SEC_STATUSES       = App::Model::SecRequestRepository::SEC_STATUSES
          @ACTIVE_STATUSES    = App::Model::SecRequestRepository::ACTIVE_STATUSES
        end

        # =====================================================================
        # ENTRY
        # =====================================================================
        def execute
          log_header

          @contracts.each_with_index do |cn, idx|
            @contract_number = cn
            reset_item_state

            log_phase("Processing #{idx + 1}/#{@contracts.size}: contract #{cn}")

            result = process_single_contract
            @all_results << result
          rescue => e
            log_error("Unhandled error: #{e.class} - #{e.message}")
            @all_results << build_exit_result(
              exit_point: "0.1",
              exit_type: "error",
              jira_comment: "❌ خطأ غير متوقع أثناء معالجة العقد #{cn}\n\n#{e.class}: #{e.message}",
              ticket_status: "need_confirmation"
            )
          end

          build_batch_result
        end

        # =====================================================================
        # MAIN PIPELINE (PHASED)
        # =====================================================================
        def process_single_contract
          # Phase 1
          pre = phase_preflight_find_and_validate_contract
          return build_exit_result(**pre) unless pre[:continue]
        
          # Phase 2
          find_mi = phase_fetch_move_in_requests
          return build_exit_result(**find_mi) unless find_mi[:continue]
        
          # Phase 3
          mo = phase_process_move_out_for_mis
          return build_exit_result(**mo)
        end        

        # =====================================================================
        # PHASE 1 — CONTRACT PREFLIGHT
        # =====================================================================
        def phase_preflight_find_and_validate_contract
          log_phase("Phase 1: Contract preflight")

          @contract = @contract_repository.find_by({ contract_number: @contract_number })

          unless @contract
            log_error("Contract not found")
            return {
              continue: false,
              exit_point: "1.1",
              exit_type: "error",
              jira_comment: "❌ لم يتم العثور على العقد رقم #{@contract_number}",
              ticket_status: "need_confirmation"
            }
          end

          if INACTIVE_CONTRACT_STATES.include?(@contract.state.to_s)
            log_error("Contract inactive: #{@contract.state}")
            return {
              continue: false,
              exit_point: "1.2",
              exit_type: "error",
              jira_comment: "❌ العقد رقم #{@contract_number} حالته #{@contract.state}، ولا توجد طلبات نقل خدمة دخول (MI) صالحة لمعالجة الخروج (MO).",
              ticket_status: "need_confirmation"
            }
          end

          log_success("Contract OK (#{@contract.id}, state=#{@contract.state})")
          { continue: true }
        end

        # =====================================================================
        # PHASE 2 — FETCH MOVE-IN REQUESTS
        # =====================================================================
        def phase_fetch_move_in_requests
          log_phase("Phase 2: Fetch eligible MI requests")

          @mi_requests = @request_repository.index(
            filters: {
              contract_number: @contract_number,
              request_type: "move_in",
              status__in: [
                @SEC_REQUEST_STATUS[:to_be_transferred],
                @SEC_REQUEST_STATUS[:approved],
                @SEC_REQUEST_STATUS[:transferred],
                @SEC_REQUEST_STATUS[:pending],
                @SEC_REQUEST_STATUS[:waiting_parties]
              ]
            },
            page: 1,
            items_per_page: 50,
            sort: { created_at: -1 }
          )

          if @mi_requests.blank?
            log_error("No eligible MI found")
            return {
              continue: false,
              exit_point: "2.1",
              exit_type: "error",
              jira_comment: "❌ لا توجد طلبات دخول (MI) صالحة للعقد #{@contract_number} لمعالجة الخروج (MO).",
              ticket_status: "need_confirmation"
            }
          end

          log_success("Found #{@mi_requests.size} MI request(s)")
          { continue: true }
        end

        # =====================================================================
        # PHASE 3 — PROCESS MO FOR EACH MI
        # =====================================================================
        def phase_process_move_out_for_mis
          log_phase("Phase 3: Process MO per MI")

          done_msgs   = []
          undone_msgs = []
          error_rns   = [] # MO request_numbers that have message_error

          @mi_requests.each do |mi|
            # 3.0: same day guard (no MI + MO same date)
            if mi.move_in_date&.to_date == Date.current
              log_warning("MI and MO same day not allowed")
              undone_msgs << "#{@contract_number}: MI and MO request cannot be processed on the same day."
              next
            end

            status = mi.status
            case status
            when @SEC_REQUEST_STATUS[:to_be_transferred],
                @SEC_REQUEST_STATUS[:pending],
                @SEC_REQUEST_STATUS[:waiting_parties]
              # Cancel non-finalized MI to clean the lane
              log_info("Canceling MI status=#{status}")
              @request_repository.no_event do
                @request_repository.update!(mi._id, {
                  status: @SEC_REQUEST_STATUS[:canceled],
                  updated_at: Time.current
                })
              end
              done_msgs << "#{@contract_number}: MI (#{status}) تم إلغاؤه لتهيئة معالجة MO."

            when @SEC_REQUEST_STATUS[:approved], @SEC_REQUEST_STATUS[:transferred]
              # 3.1: If an APPROVED MO already exists → success
              approved_mo = @request_repository.find_by({
                premise_id: mi.premise_id,
                request_type: "move_out",
                contract_id: mi.contract_id,
                unit_number: mi.unit_number,
                status__in: @ACTIVE_STATUSES
              })

              if approved_mo
                log_success("MO already processed (#{approved_mo.request_number})")
                done_msgs << "#{@contract_number}: MO request #{approved_mo.request_number} is processed successfully for the unit_number #{approved_mo.unit_number}"
                next
              end

              # 3.2 / 3.3: Trigger pending MO or create new MO then send
              outcome = trigger_or_create_and_send_mo!(mi, error_rns)
              (outcome[:ok] ? done_msgs : undone_msgs) << outcome[:message]

            else
              log_info("Skipping MI (status=#{status})")
            end
          rescue => e
            log_error("MI loop error: #{e.message}")
            undone_msgs << "#{@contract_number}: #{e.message}"
          end

          # Print MO requests with error messages (for operator visibility)
          if error_rns.any?
            log_step("MO requests with message_error")
            error_rns.each do |rn|
              mo = @request_repository.find_by!({ request_number: rn })
              puts "#{rn}: #{mo.message_error['en']}"
            end
          end

          # Decide final exit based on messages gathered
          final_comment = (done_msgs + undone_msgs).join("\n")

          if done_msgs.any? && undone_msgs.empty?
            {
              exit_point: "3.4",
              exit_type: "success",
              jira_comment: "✅ تمت المعالجة بنجاح:\n\n#{final_comment}",
              ticket_status: "need_confirmation"
            }
          elsif done_msgs.any? && undone_msgs.any?
            {
              exit_point: "3.5",
              exit_type: "warning",
              jira_comment: "⚠️ تم تنفيذ بعض العمليات وفشلت أخرى:\n\n#{final_comment}",
              ticket_status: "need_confirmation"
            }
          else
            {
              exit_point: "3.6",
              exit_type: "error",
              jira_comment: "❌ فشلت جميع المحاولات:\n\n#{final_comment}",
              ticket_status: "need_confirmation"
            }
          end
        end

        # =====================================================================
        # CORE ACTION: trigger existing pending MO or create+send a new MO
        # Maps outcomes to exit sub-points 4.x
        # =====================================================================
        def trigger_or_create_and_send_mo!(mi, error_rns)
          # A) If there are pending MOs → trigger latest and cancel others
          pending = @request_repository.index(
            filters: {
              contract_id: @contract.id,
              unit_number: mi.unit_number,
              premise_id: mi.premise_id,
              request_type: "move_out",
              status__in: ["pending", "waiting_parties"]
            },
            page: 1,
            items_per_page: 100,
            sort: { created_at: -1 }
          )

          if pending.any?
            mo_to_trigger, *to_cancel = pending
            to_cancel.each do |r|
              @request_repository.update!(r._id, { status: "canceled", updated_at: Time.current })
            end

            begin
              _, call_id = App::Services::MoveOutRequest::Send
                            .new(EFrame::Iam.system_context)
                            .call(mo_to_trigger, @contract)

              if call_id.present?
                log_success("Triggered pending MO (#{mo_to_trigger.request_number})")
                return { ok: true, message: "#{@contract_number}: OUT request is processed successfully for the unit_number #{mi.unit_number}" }
              else
                mo = @request_repository.find_by!({ request_number: mo_to_trigger.request_number })
                error_rns << mo_to_trigger.request_number
                return {
                  ok: false,
                  message: "#{@contract_number}: OUT request is triggered but failed for the unit_number #{mi.unit_number}, due to the error: #{mo.message_error['en']}"
                }
              end
            rescue => _
              mo = @request_repository.find_by!({ request_number: mo_to_trigger.request_number })
              error_rns << mo_to_trigger.request_number
              return {
                ok: false,
                message: "#{@contract_number}: MO request is triggered but failed for the unit_number #{mi.unit_number}, due to the error: #{mo_to_trigger.message_error['en']}"
              }
            end
          end

          # B) No pending MO → create new MO
          begin
            App::Services::Validation::MoveOutValidation.validate(
              mi_request: mi,
              mo_date: Date.current
            )
          rescue => e
            log_error("MoveOutValidation failed: #{e.message}")
            return {
              ok: false,
              message: "#{@contract_number}: Move out validation failed for the unit_number #{mi.unit_number}, #{e.message}"
            }
          end

          request_obj = build_mo_request_from_mi(mi)

          # Optional enrichment via SEC.AccountCheck
          if request_obj[:account_no].present?
            enrich_mo_request_from_account_check!(request_obj)
          end

          request_obj[:request_number] = App::Utils::Token.unique_human_readable_token

          id = @request_repository.create(request_obj)
          created = @request_repository.find_by!({ _id: BSON::ObjectId(id) })

          begin
            _, call_id = App::Services::MoveOutRequest::Send
                          .new(EFrame::Iam.system_context)
                          .call(created, @contract)

            if call_id.present?
              log_success("Created+sent MO (#{created.request_number})")
              { ok: true, message: "#{@contract_number}: MO request is processed successfully for the unit_number #{mi.unit_number}" }
            else
              mo = @request_repository.find_by!({ _id: BSON::ObjectId(id) })
              error_rns << created.request_number
              {
                ok: false,
                message: "#{@contract_number}: MO request is triggered but failed for the unit_number #{mi.unit_number}, due to the error: #{mo.message_error['en']}"
              }
            end
          rescue => _
            mo = @request_repository.find_by!({ _id: BSON::ObjectId(id) })
            error_rns << created.request_number
            {
              ok: false,
              message: "#{@contract_number}: MO request is triggered but failed for the unit_number #{mi.unit_number}, due to the error: #{mo.message_error['en']}"
            }
          end
        end

        def build_mo_request_from_mi(mi)
          {
            request_type: "move_out",
            status: @SEC_REQUEST_STATUS[:pending],
            request_date: Date.current.strftime("%Y-%m-%d"),
            move_out_date: Date.current.strftime("%Y-%m-%d"),
            meter_reading_date: Date.current.strftime("%Y-%m-%d"),
            electricity_current_reading: nil,
            move_in_request_id: mi.id.to_s,
            created_by: "system",
            updated_at: Time.current,
            created_at: Time.current,
            sec_status: @SEC_STATUSES["in_progress"]
          }.merge(
            mi.fields.slice(
              :contract_id,
              :contract_unit_service_id,
              :premise_id,
              :site_scenario,
              :equipment_number,
              :meter_number,
              :meter_type,
              :contract_number,
              :tenant_pay_outstanding,
              :move_in_date,
              :unit_number,
              :contract_change_history,
              :notification_number,
              :account_no
            )
          )
        end

        def enrich_mo_request_from_account_check!(request_obj)
          params = { ContractAccount: request_obj[:account_no] }
          external_call = ExternalCalls.service.call(
            "SEC.AccountCheck",
            params: params,
            priority: ExternalCalls::Model::Call::PRIORITY_SYNC
          )

          payload = external_call&.payload
          resp = payload&.dig("Body", "EJARAccountCheckResponse")
          return unless resp

          request_obj[:account_check_call_id] = external_call._id.is_a?(String) ? external_call._id : external_call._id["$oid"]
          request_obj[:meter_number]          = resp.dig("EJARAccountCheck", "MeterDetails", "MeterNumber").to_s.strip
          request_obj[:site_scenario]         = resp.dig("EJARAccountCheck", "SiteScenario").to_s.strip
          request_obj[:equipment_number]      = resp.dig("EJARAccountCheck", "MeterDetails", "EquipmentNumber").to_s.strip
          request_obj[:premise_outstanding_balance] = resp.dig("EJARAccountCheck", "OutstandingBalanceofPremise").to_s.strip

          if resp.dig("EJARAccountCheck", "ProposedMeterRead").to_i > 0
            request_obj[:proposed_meter_reading] = resp.dig("EJARAccountCheck", "ProposedMeterRead")
          end
        rescue => e
          log_warning("AccountCheck enrichment failed: #{e.message}")
        end

        # =====================================================================
        # RESULT BUILDERS
        # =====================================================================
        def build_exit_result(exit_point:, exit_type:, jira_comment:, ticket_status:, should_close_ticket: false)
          {
            input: { contract_number: @contract_number },
            exit_point: exit_point,
            exit_type: exit_type,
            jira_comment: jira_comment,
            ticket_status: ticket_status,
            should_close_ticket: should_close_ticket,
            phase_reached: "sec_move_out"
          }
        end

        def build_batch_result
          {
            script_name: "sec_move_out_orchestrator.rb",
            result: {
              batch_mode: @contracts.size > 1,
              total_contracts: @contracts.size,
              results: @all_results,
              execution_log: @execution_log
            }
          }
        end

        # =====================================================================
        # LOGGING
        # =====================================================================
        def log_header
          pp "=" * 100
          pp "SEC MOVE-OUT ORCHESTRATOR"
          pp "=" * 100
          pp "Contracts to process: #{@contracts.size}"
          pp "Debug mode: #{@debug_mode}"
          pp "=" * 100
        end

        def log_phase(msg)
          pp "\n" + "═" * 100
          pp "▶▶ #{msg}"
          pp "═" * 100
          @execution_log << { type: "phase", message: msg, timestamp: Time.current }
        end

        def log_step(msg)
          pp "\n" + "─" * 80
          pp "▶ #{msg}"
          @execution_log << { type: "step", message: msg, timestamp: Time.current }
        end

        def log_success(msg); pp "  ✅ #{msg}"; @execution_log << { type: "success", message: msg, timestamp: Time.current }; end
        def log_error(msg);   pp "  ❌ #{msg}"; @execution_log << { type: "error",   message: msg, timestamp: Time.current }; end
        def log_info(msg);    pp "  ℹ️  #{msg}"; @execution_log << { type: "info",    message: msg, timestamp: Time.current }; end
        def log_warning(msg); pp "  ⚠️  #{msg}"; @execution_log << { type: "warning", message: msg, timestamp: Time.current }; end

        def reset_item_state
          @contract = nil
          @mi_requests = []
        end
      end

      result = SecMoveOutOrchestrator.new(contracts: ["10758399889"]).execute
      puts "ExecutionResult: #{result.to_json}"
    end
  end
end

