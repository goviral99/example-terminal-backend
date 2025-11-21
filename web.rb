require 'sinatra'
require 'stripe'
require 'dotenv'
require 'json'
require 'sinatra/cross_origin'

# --------------------------------------------------
# CORS CONFIG
# --------------------------------------------------
configure do
  enable :cross_origin
end

before do
  response.headers['Access-Control-Allow-Origin'] = '*'
end

options "*" do
  response.headers["Allow"] = "GET, POST, OPTIONS"
  response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, Accept, X-User-Email, X-Auth-Token"
  response.headers["Access-Control-Allow-Origin"] = "*"
  200
end

# --------------------------------------------------
# STRIPE CONFIG (LIVE MODE)
# --------------------------------------------------
Dotenv.load
Stripe.api_key = ENV['STRIPE_SECRET_KEY']
Stripe.api_version = '2020-03-02'

# --------------------------------------------------
# ENHANCED LOGGING FUNCTIONS
# --------------------------------------------------
def log_info(message, data = nil)
  timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
  puts "\n[INFO #{timestamp}] #{message}"
  puts JSON.pretty_generate(data) if data
  puts "\n"
  message
end

def log_error(message, error = nil, context = nil)
  timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
  puts "\n[ERROR #{timestamp}] #{message}"
  if error
    puts "Error Type: #{error.class}"
    puts "Error Message: #{error.message}"
    puts "Error Code: #{error.code}" if error.respond_to?(:code)
    puts "Decline Code: #{error.decline_code}" if error.respond_to?(:decline_code)
    puts "Param: #{error.param}" if error.respond_to?(:param)
    puts "Error JSON: #{error.json_body}" if error.respond_to?(:json_body)
  end
  puts "Context: #{JSON.pretty_generate(context)}" if context
  puts "\n"
end

def log_payment_details(payment_intent)
  if payment_intent.latest_charge
    charge = payment_intent.latest_charge
    details = {
      payment_intent_id: payment_intent.id,
      status: payment_intent.status,
      amount: payment_intent.amount,
      currency: payment_intent.currency,
      payment_method_types: payment_intent.payment_method_types
    }
    
    if charge.payment_method_details
      if charge.payment_method_details.card_present
        details[:card_present] = {
          brand: charge.payment_method_details.card_present.brand,
          network: charge.payment_method_details.card_present.network,
          funding: charge.payment_method_details.card_present.funding,
          last4: charge.payment_method_details.card_present.last4,
          exp_month: charge.payment_method_details.card_present.exp_month,
          exp_year: charge.payment_method_details.card_present.exp_year,
          cardholder_name: charge.payment_method_details.card_present.cardholder_name,
          read_method: charge.payment_method_details.card_present.read_method
        }
      end
      
      if charge.payment_method_details.interac_present
        details[:interac_present] = {
          brand: charge.payment_method_details.interac_present.brand,
          network: charge.payment_method_details.interac_present.network,
          cardholder_name: charge.payment_method_details.interac_present.cardholder_name,
          last4: charge.payment_method_details.interac_present.last4,
          read_method: charge.payment_method_details.interac_present.read_method,
          receipt_account_type: charge.payment_method_details.interac_present.receipt_account_type
        }
      end
    end
    
    if charge.outcome
      details[:outcome] = {
        network_status: charge.outcome.network_status,
        reason: charge.outcome.reason,
        risk_level: charge.outcome.risk_level,
        seller_message: charge.outcome.seller_message,
        type: charge.outcome.type
      }
    end
    
    details[:failure_code] = charge.failure_code if charge.failure_code
    details[:failure_message] = charge.failure_message if charge.failure_message
    
    log_info("Payment Details", details)
  end
end

# --------------------------------------------------
# HOME
# --------------------------------------------------
get '/' do
  status 200
  "Stripe Tap-to-Pay LIVE Backend Running (with Interac Debug)"
end

# --------------------------------------------------
# REGISTER READER (for hardware readers only)
# --------------------------------------------------
post '/register_reader' do
  begin
    log_info("Registering reader", {
      registration_code: params[:registration_code],
      label: params[:label],
      location: params[:location]
    })
    
    reader = Stripe::Terminal::Reader.create(
      registration_code: params[:registration_code],
      label: params[:label],
      location: params[:location]
    )
    
    log_info("Reader registered successfully", { reader_id: reader.id })
  rescue Stripe::StripeError => e
    log_error("Error registering reader", e)
    status 402
    return { error: e.message, code: e.code }.to_json
  end

  status 200
  return reader.to_json
end

# --------------------------------------------------
# CONNECTION TOKEN (Tap-to-Pay & Readers)
# --------------------------------------------------
post '/connection_token' do
  begin
    token = Stripe::Terminal::ConnectionToken.create
    log_info("ConnectionToken created", { secret: token.secret[0..10] + "..." })
  rescue Stripe::StripeError => e
    log_error("Error creating ConnectionToken", e)
    status 402
    return { error: e.message, code: e.code }.to_json
  end

  content_type :json
  status 200
  return { secret: token.secret }.to_json
end

# --------------------------------------------------
# CREATE PAYMENT INTENT (Enhanced for Interac)
# --------------------------------------------------
post '/create_payment_intent' do
  begin
    amount = params[:amount].to_i
    
    if amount <= 0
      log_error("Invalid amount", nil, { amount: params[:amount] })
      status 400
      return { error: "Invalid amount" }.to_json
    end
    
    # Log the incoming request
    log_info("Creating PaymentIntent", {
      amount: amount,
      currency: 'cad',
      payment_method_types: ['card_present', 'interac_present'],
      capture_method: params[:capture_method] || 'manual'
    })

    payment_intent = Stripe::PaymentIntent.create(
      amount: amount,
      currency: 'cad',
      payment_method_types: ['card_present', 'interac_present'],
      capture_method: params[:capture_method] || 'manual',
      payment_method_options: {
        card_present: {
          request_extended_authorization: false,
          request_incremental_authorization_support: false
        },
        interac_present: {}
      },
      metadata: {
        source: 'tap_to_pay',
        timestamp: Time.now.to_i,
        terminal_sdk: 'android'
      },
      description: params[:description] || 'Tap-to-Pay Payment',
      receipt_email: params[:receipt_email]
    )
    
    log_info("PaymentIntent created successfully", {
      id: payment_intent.id,
      status: payment_intent.status,
      client_secret: payment_intent.client_secret[0..20] + "..."
    })
    
  rescue Stripe::StripeError => e
    log_error("Error creating PaymentIntent", e, {
      amount: amount,
      params: params
    })
    status 402
    return { 
      error: e.message,
      code: e.code,
      type: e.class.to_s,
      param: e.param
    }.to_json
  end

  status 200
  return {
    intent: payment_intent.id,
    secret: payment_intent.client_secret
  }.to_json
end

# --------------------------------------------------
# GET PAYMENT INTENT (NEW - For debugging)
# --------------------------------------------------
get '/payment_intent/:id' do
  begin
    intent = Stripe::PaymentIntent.retrieve(
      params[:id],
      { expand: ['latest_charge', 'payment_method', 'latest_charge.outcome', 'latest_charge.payment_method_details'] }
    )
    
    log_payment_details(intent)
    
    content_type :json
    return intent.to_json
  rescue Stripe::StripeError => e
    log_error("Error retrieving PaymentIntent", e, { id: params[:id] })
    status 402
    return { error: e.message }.to_json
  end
end

# --------------------------------------------------
# CAPTURE PAYMENT INTENT (Enhanced)
# --------------------------------------------------
post '/capture_payment_intent' do
  begin
    id = params["payment_intent_id"]
    
    if id.nil?
      log_error("Missing payment_intent_id")
      status 400
      return { error: "Missing payment_intent_id" }.to_json
    end
    
    log_info("Attempting to capture PaymentIntent", { id: id })
    
    # First retrieve to check status
    intent = Stripe::PaymentIntent.retrieve(
      id,
      { expand: ['latest_charge', 'latest_charge.outcome', 'latest_charge.payment_method_details'] }
    )
    
    log_info("PaymentIntent status before capture", {
      id: intent.id,
      status: intent.status,
      amount_capturable: intent.amount_capturable
    })
    
    # Capture the payment
    if params["amount_to_capture"]
      intent = Stripe::PaymentIntent.capture(id, amount_to_capture: params["amount_to_capture"])
    else
      intent = Stripe::PaymentIntent.capture(id)
    end
    
    log_info("PaymentIntent captured successfully", {
      id: intent.id,
      status: intent.status,
      amount_received: intent.amount_received
    })
    
    # Log full payment details after capture
    log_payment_details(intent)
    
  rescue Stripe::StripeError => e
    log_error("Error capturing PaymentIntent", e, { 
      payment_intent_id: id,
      amount_to_capture: params["amount_to_capture"]
    })
    status 402
    return { 
      error: e.message,
      code: e.code,
      decline_code: e.decline_code
    }.to_json
  end

  status 200
  return {
    intent: intent.id,
    status: intent.status,
    secret: intent.client_secret
  }.to_json
end

# --------------------------------------------------
# CANCEL PAYMENT INTENT
# --------------------------------------------------
post '/cancel_payment_intent' do
  begin
    id = params["payment_intent_id"]
    
    if id.nil?
      log_error("Missing payment_intent_id")
      status 400
      return { error: "Missing payment_intent_id" }.to_json
    end
    
    log_info("Canceling PaymentIntent", { id: id })
    
    intent = Stripe::PaymentIntent.cancel(id)
    
    log_info("PaymentIntent canceled", {
      id: intent.id,
      status: intent.status
    })
    
  rescue Stripe::StripeError => e
    log_error("Error canceling PaymentIntent", e, { payment_intent_id: id })
    status 402
    return { error: e.message, code: e.code }.to_json
  end

  status 200
  return {
    intent: intent.id,
    secret: intent.client_secret
  }.to_json
end

# --------------------------------------------------
# WEBHOOK HANDLER (NEW - For real-time debugging)
# --------------------------------------------------
post '/webhook' do
  payload = request.body.read
  sig_header = request.env['HTTP_STRIPE_SIGNATURE']
  endpoint_secret = ENV['STRIPE_WEBHOOK_SECRET'] # Add to your .env file

  begin
    event = nil
    
    if endpoint_secret
      event = Stripe::Webhook.construct_event(
        payload, sig_header, endpoint_secret
      )
    else
      # For testing without webhook signature verification
      event = JSON.parse(payload)
    end
    
  rescue JSON::ParserError => e
    log_error("Webhook JSON parse error", e)
    status 400
    return
  rescue Stripe::SignatureVerificationError => e
    log_error("Webhook signature verification failed", e)
    status 400
    return
  end

  # Handle the event
  case event['type']
  when 'payment_intent.created'
    payment_intent = event['data']['object']
    log_info("WEBHOOK: Payment Intent Created", {
      id: payment_intent['id'],
      amount: payment_intent['amount']
    })
    
  when 'payment_intent.succeeded'
    payment_intent = event['data']['object']
    log_info("WEBHOOK: Payment Succeeded", {
      id: payment_intent['id'],
      amount: payment_intent['amount']
    })
    
  when 'payment_intent.payment_failed'
    payment_intent = event['data']['object']
    log_error("WEBHOOK: Payment Failed", nil, {
      id: payment_intent['id'],
      last_payment_error: payment_intent['last_payment_error']
    })
    
  when 'charge.succeeded'
    charge = event['data']['object']
    log_info("WEBHOOK: Charge Succeeded", {
      id: charge['id'],
      amount: charge['amount'],
      payment_method_details: charge['payment_method_details']
    })
    
  when 'charge.failed'
    charge = event['data']['object']
    log_error("WEBHOOK: Charge Failed", nil, {
      id: charge['id'],
      failure_code: charge['failure_code'],
      failure_message: charge['failure_message'],
      outcome: charge['outcome']
    })
  else
    log_info("WEBHOOK: Unhandled event type", { type: event['type'] })
  end

  status 200
end

# --------------------------------------------------
# SETUP INTENT
# --------------------------------------------------
post '/create_setup_intent' do
  begin
    setup_intent_params = {
      payment_method_types: params[:payment_method_types] || ['card_present']
    }

    setup_intent_params[:customer] = params[:customer] if params[:customer]
    setup_intent_params[:description] = params[:description] if params[:description]
    setup_intent_params[:on_behalf_of] = params[:on_behalf_of] if params[:on_behalf_of]

    log_info("Creating SetupIntent", setup_intent_params)

    setup_intent = Stripe::SetupIntent.create(setup_intent_params)
    
    log_info("SetupIntent created", { id: setup_intent.id })
    
  rescue Stripe::StripeError => e
    log_error("Error creating SetupIntent", e)
    status 402
    return { error: e.message }.to_json
  end

  status 200
  return {
    intent: setup_intent.id,
    secret: setup_intent.client_secret
  }.to_json
end

# --------------------------------------------------
# ATTACH PAYMENT METHOD TO CUSTOMER
# --------------------------------------------------
post '/attach_payment_method_to_customer' do
  begin
    # You'll need to implement lookupOrCreateExampleCustomer
    # For now, create a new customer
    customer = Stripe::Customer.create(
      description: 'Tap to Pay Customer'
    )

    payment_method = Stripe::PaymentMethod.attach(
      params[:payment_method_id],
      { customer: customer.id, expand: ["customer"] }
    )
    
    log_info("Payment method attached", {
      payment_method_id: params[:payment_method_id],
      customer_id: customer.id
    })
    
  rescue Stripe::StripeError => e
    log_error("Error attaching PaymentMethod", e)
    status 402
    return { error: e.message }.to_json
  end

  status 200
  return payment_method.to_json
end

# --------------------------------------------------
# UPDATE PAYMENT INTENT
# --------------------------------------------------
post '/update_payment_intent' do
  payment_intent_id = params["payment_intent_id"]
  
  if payment_intent_id.nil?
    log_error("Missing payment_intent_id")
    status 400
    return { error: "'payment_intent_id' is required" }.to_json
  end

  begin
    allowed_keys = ["receipt_email", "description", "metadata"]
    update_params = params.select { |k, _| allowed_keys.include?(k) }
    
    log_info("Updating PaymentIntent", {
      id: payment_intent_id,
      updates: update_params
    })

    intent = Stripe::PaymentIntent.update(payment_intent_id, update_params)
    
    log_info("PaymentIntent updated", { id: payment_intent_id })
    
  rescue Stripe::StripeError => e
    log_error("Error updating PaymentIntent", e, { 
      payment_intent_id: payment_intent_id 
    })
    status 402
    return { error: e.message }.to_json
  end

  status 200
  return {
    intent: intent.id,
    secret: intent.client_secret
  }.to_json
end

# --------------------------------------------------
# LIST LOCATIONS
# --------------------------------------------------
get '/list_locations' do
  begin
    locations = Stripe::Terminal::Location.list(limit: 100)
    log_info("Locations retrieved", { count: locations.data.length })
  rescue Stripe::StripeError => e
    log_error("Error fetching locations", e)
    status 402
    return { error: e.message }.to_json
  end

  content_type :json
  return locations.data.to_json
end

# --------------------------------------------------
# CREATE LOCATION
# --------------------------------------------------
post '/create_location' do
  begin
    log_info("Creating location", {
      display_name: params[:display_name],
      address: params[:address]
    })
    
    location = Stripe::Terminal::Location.create(
      display_name: params[:display_name],
      address: params[:address]
    )
    
    log_info("Location created", { id: location.id })
    
  rescue Stripe::StripeError => e
    log_error("Error creating location", e)
    status 402
    return { error: e.message }.to_json
  end

  content_type :json
  return location.to_json
end

# --------------------------------------------------
# DEBUG ENDPOINT - Test Interac Support (NEW)
# --------------------------------------------------
get '/debug/check_interac_support' do
  begin
    # Check account capabilities
    account = Stripe::Account.retrieve
    
    result = {
      country: account.country,
      default_currency: account.default_currency,
      capabilities: account.capabilities,
      charges_enabled: account.charges_enabled,
      payouts_enabled: account.payouts_enabled
    }
    
    log_info("Account Interac Support Check", result)
    
    content_type :json
    return result.to_json
  rescue Stripe::StripeError => e
    log_error("Error checking Interac support", e)
    status 402
    return { error: e.message }.to_json
  end
end
