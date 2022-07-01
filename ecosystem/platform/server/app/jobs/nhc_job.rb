# frozen_string_literal: true

# Copyright (c) Aptos
# SPDX-License-Identifier: Apache-2.0

class NhcJob < ApplicationJob
  # Ex args: { it2_profile_id: 32, do_location: true }
  def perform(args)
    @it2_profile = It2Profile.find(args[:it2_profile_id])
    do_location = args[:do_location]
    sentry_scope.set_user(id: @it2_profile.user_id)
    sentry_scope.set_context(:job_info, { validator_address: @it2_profile.validator_address })

    nhc = NodeHelper::NodeChecker.new(ENV.fetch('NODE_CHECKER_BASE_URL'),
                                      @it2_profile.validator_address,
                                      @it2_profile.validator_metrics_port,
                                      @it2_profile.validator_api_port,
                                      @it2_profile.validator_port)

    @it2_profile.update_attribute(:validator_verified, false)

    unless nhc.ip.ok
      write_status("Error fetching IP for #{@it2_profile.validator_address}: #{nhc.ip.message}")
      return
    end

    results = nhc.verify(ENV.fetch('NODE_CHECKER_BASELINE_CONFIG'))

    unless results.ok
      write_status(results.message)
      return
    end

    # Save without validation to avoid needless uniqueness checks
    is_valid = results.evaluation_results.map { |r| r.score == 100 }.all?
    @it2_profile.update_attribute(:validator_verified, is_valid)

    LocationJob.perform_later({ it2_profile_id: @it2_profile.id }) if is_valid && do_location

    failures = []
    results.evaluation_results.each do |result|
      next unless result.score < 100

      message = "#{result.category}: #{result.evaluator_name} - #{result.score}\n" \
                "#{result.headline}:\n" \
                "#{result.explanation}\n" \
                "#{result.links}\n"
      failures.push(message)
    end

    result = failures.join("\n\n")
    result = 'Node validated successfully!' if is_valid
    write_status(result)
    @it2_profile.user.maybe_send_ait2_registration_complete_email
  end

  def write_status(status)
    @it2_profile.nhc_job_id = nil
    @it2_profile.nhc_output = status
    @it2_profile.save!
  end
end