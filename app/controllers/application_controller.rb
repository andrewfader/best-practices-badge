# frozen_string_literal: true

# Copyright 2015-2017, the Linux Foundation, IDA, and the
# CII Best Practices badge contributors
# SPDX-License-Identifier: MIT

require 'ipaddr'

class ApplicationController < ActionController::Base
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception

  # For the PaperTrail gem
  before_action :set_paper_trail_whodunnit

  # Limit time before must log in again.
  before_action :validate_session_timestamp
  after_action :persist_session_timestamp

  # If locale is not provided in the URL, redirect to best option.
  before_action :redir_missing_locale

  # Set the locale, based on best available information.
  before_action :set_locale_to_best_available

  # Force http -> https
  before_action :redirect_https

  # Validate client IP address (if only some IP addresses are allowed);
  # counters cloud piercing.
  before_action :validate_client_ip_address

  # Record user_id, e.g., so it can be recorded in logs
  # https://github.com/roidrage/lograge/issues/23
  def append_info_to_payload(payload)
    super
    payload[:uid] = current_user.id if logged_in?
  end

  private

  # *Always* include the locale when generating a URL.
  # Historically we omitted the locale when it was "en", but then we could
  # not tell the difference between "use en" and "use the browser's locale".
  # So, we now *always* include the locale in the URL once we know what it is;
  # if there's no locale in the URL, that means we must use heuristics
  # to figure out what it should be and redirect to that locale.
  # To omit the locale for "en",
  # see this: http://stackoverflow.com/questions/5261521/
  # how-to-avoid-adding-the-default-locale-in-generated-urls
  # { locale: I18n.locale == I18n.default_locale ? nil : I18n.locale }
  # rubocop: disable Style/OptionHash
  def default_url_options(options = {})
    { locale: I18n.locale }.merge options
  end
  # rubocop: enable Style/OptionHash

  # raise exception if text value client_ip isn't in valid_client_ips
  def fail_if_invalid_client_ip(client_ip, allowed_ips)
    return if client_ip.blank?
    client_ip_data = IPAddr.new(client_ip)
    return unless client_ip_data
    return if allowed_ips.any? do |range|
      range.include?(client_ip_data)
    end
    raise ActionController::RoutingError.new('Invalid client IP'),
          'Invalid client IP'
  end

  # See: http://stackoverflow.com/questions/4329176/
  #   rails-how-to-redirect-from-http-example-com-to-https-www-example-com
  def redirect_https
    if Rails.application.config.force_ssl && !request.ssl?
      redirect_to protocol: 'https://', status: :moved_permanently
    end
    true
  end

  # Find the best-matching locale,
  # because the user did not specify a locale in the URL.
  # We use the following rules:
  # 1. Use the browser's ACCEPT_LANGUAGE best-matching locale
  # in automatic_locales (if the browser gives us a matching one).
  # 2. Otherwise, fall back to the I18n.default_locale value.
  # Note that the user can *ALWAYS* express the preferred locale in the URL.
  # We do *NOT* use cookies (these aren't RESTful and thus cause problems),
  # and users can always override with a URL even if their browser's locale
  # is not configured correctly.
  # We could use geolocation in the future, but we would only do so if
  # the user hasn't specified a locale in the URL *and* the browser hasn't
  # requested a locale.  Geolocation is problematic: some user's locales
  # will not be the common one in the geolocation, and we must avoid
  # online services (that would leak user IP addresses to those services).
  # Browsers often provide ACCEPT_LANGUAGE (which in turn is often provided
  # by the operating system), so we should not need geolocation anyway.
  def find_best_locale
    browser_locale =
      http_accept_language.preferred_language_from(
        Rails.application.config.automatic_locales
      )
    return browser_locale if browser_locale.present?
    I18n.default_locale
  end

  # If locale is not provided in the URL, redirect to best option.
  # NOTE: This is intentionally skipped by some calls, e.g., session create.
  # See <http://guides.rubyonrails.org/i18n.html>.
  def redir_missing_locale
    explicit_locale = params[:locale]
    return if explicit_locale.present?
    #
    # Special case: If the requested format is JSON, don't bother
    # redirecting, because JSON is the same in any locale.
    #
    return if params[:format] == 'json'
    #
    # No locale, determine the best locale and redirect.
    #
    best_locale = find_best_locale
    preferred_url = force_locale_url(request.original_url, best_locale)
    # It's not clear what status code to provide on a locale-based redirect.
    # However, we must avoid 301 (Moved Permanently), because it is certainly
    # not a permanent move.  For the moment we'll use 300 (Multiple Choices),
    # because that code indicates there's a redirect based on agent choices
    # (which is certainly true).
    redirect_to preferred_url, status: :multiple_choices # 300
  end

  # Set the locale, based on best available information.
  # See <http://guides.rubyonrails.org/i18n.html>.
  def set_locale_to_best_available
    best_locale = params[:locale]
    best_locale = find_best_locale if best_locale.blank?

    # Assigning a value to I18n.locale *looks* like a
    # global variable setting, and setting a global
    # variable would be bad since we're multi-threaded.
    # However, this is *not* setting a global variable, it's setting a
    # per-Thread value (which is safe). Per the i18n guide,
    # "The locale can be either set pseudo-globally to I18n.locale
    # (which uses Thread.current like, e.g., Time.zone)...".
    I18n.locale = best_locale.to_sym
  end

  # Validate client IP address if Rails.configuration.valid_client_ips
  # and header value X-Forwarded-For.
  # This can provide a defense against cloud piercing.
  def validate_client_ip_address
    return unless Rails.configuration.valid_client_ips
    client_ip = request.remote_ip
    fail_if_invalid_client_ip(client_ip, Rails.configuration.valid_client_ips)
  end

  include SessionsHelper
end
