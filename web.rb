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
Stripe.api_key = ENV['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']   # LIVE KEY
Stripe.api_version = '2020-03-02'

def log_info(message)
  puts "\n#{message}\n\n"
  message
end

# --------------------------------------------------
# HOME
# --------------------------------------------------
get '/' do
  status 200
  "Stripe Tap-to-Pay LIVE Backend is Running"
end

# --------------------------------------------------
# REGISTER READER (for hardware readers only)
# --------------------------------------------------
post '/register_reader' do
  begin
    reader = Stripe::Terminal::Reader.create(
      registration_code: params[:registration_code],
      label: params[:label],
      location: params[:location]
    )
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error registering reader! #{e.message}")
  end

  log_info("Reader registered: #{reader.id}")

  status 200
  return reader.to_json
end

# --------------------------------------------------
# CONNECTION TOKEN (Tap-to-Pay & Readers)
# --------------------------------------------------
post '/connection_token' do
  begin
    token = Stripe::Terminal::ConnectionToken.create
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error creating ConnectionToken! #{e.message}")
  end

  content_type :json
  status 200
  return { secret: token.secret }.to_json
end

# --------------------------------------------------
# CREATE PAYMENT INTENT (Tap-to-Pay)
# --------------------------------------------------
post '/create_payment_intent' do
  begin
    amount = params[:amount].to_i
    return log_info("Missing or invalid amount") if amount <= 0

    payment_intent = Stripe::PaymentIntent.create(
      amount: amount,
      currency: 'cad',   # REQUIRED IN CANADA
      payment_method_types: ['card_present', 'interac_present'],
      capture_method: params[:capture_method] || 'manual',

      payment_method_options: {
        card_present: {},
        interac_present: {}
      },

      description: params[:description] || 'Tap-to-Pay Payment',
      receipt_email: params[:receipt_email]
    )
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error creating PaymentIntent! #{e.message}")
  end

  log_info("PaymentIntent created: #{payment_intent.id}")

  status 200
  return {
    intent: payment_intent.id,
    secret: payment_intent.client_secret
  }.to_json
end

# --------------------------------------------------
# CAPTURE PAYMENT INTENT
# --------------------------------------------------
post '/capture_payment_intent' do
  begin
    id = params["payment_intent_id"]
    return log_info("Missing payment_intent_id") if id.nil?

    intent =
      if params["amount_to_capture"]
        Stripe::PaymentIntent.capture(id, amount_to_capture: params["amount_to_capture"])
      else
        Stripe::PaymentIntent.capture(id)
      end
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error capturing PaymentIntent! #{e.message}")
  end

  log_info("PaymentIntent captured: #{id}")

  status 200
  return {
    intent: intent.id,
    secret: intent.client_secret
  }.to_json
end

# --------------------------------------------------
# CANCEL PAYMENT INTENT
# --------------------------------------------------
post '/cancel_payment_intent' do
  begin
    id = params["payment_intent_id"]
    return log_info("Missing payment_intent_id") if id.nil?

    intent = Stripe::PaymentIntent.cancel(id)
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error canceling PaymentIntent! #{e.message}")
  end

  log_info("PaymentIntent canceled: #{id}")

  status 200
  return {
    intent: intent.id,
    secret: intent.client_secret
  }.to_json
end

# --------------------------------------------------
# SETUP INTENT (optional)
# --------------------------------------------------
post '/create_setup_intent' do
  begin
    setup_intent_params = {
      payment_method_types: params[:payment_method_types] || ['card_present']
    }

    setup_intent_params[:customer] = params[:customer] if params[:customer]
    setup_intent_params[:description] = params[:description] if params[:description]
    setup_intent_params[:on_behalf_of] = params[:on_behalf_of] if params[:on_behalf_of]

    setup_intent = Stripe::SetupIntent.create(setup_intent_params)
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error creating SetupIntent! #{e.message}")
  end

  log_info("SetupIntent created: #{setup_intent.id}")

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
    customer = lookupOrCreateExampleCustomer

    payment_method = Stripe::PaymentMethod.attach(
      params[:payment_method_id],
      { customer: customer.id, expand: ["customer"] }
    )
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error attaching PaymentMethod! #{e.message}")
  end

  log_info("Attached to Customer: #{customer.id}")

  status 200
  return payment_method.to_json
end

# --------------------------------------------------
# UPDATE PAYMENTINTENT (optional)
# --------------------------------------------------
post '/update_payment_intent' do
  payment_intent_id = params["payment_intent_id"]
  return log_info("'payment_intent_id' is required") if payment_intent_id.nil?

  begin
    allowed_keys = ["receipt_email"]
    update_params = params.select { |k, _| allowed_keys.include?(k) }

    intent = Stripe::PaymentIntent.update(payment_intent_id, update_params)
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error updating PaymentIntent #{payment_intent_id}: #{e.message}")
  end

  log_info("PaymentIntent updated: #{payment_intent_id}")

  status 200
  return {
    intent: intent.id,
    secret: intent.client_secret
  }.to_json
end

# --------------------------------------------------
# LIST LOCATIONS (optional)
# --------------------------------------------------
get '/list_locations' do
  begin
    locations = Stripe::Terminal::Location.list(limit: 100)
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error fetching locations: #{e.message}")
  end

  content_type :json
  return locations.data.to_json
end

# --------------------------------------------------
# CREATE LOCATION (optional)
# --------------------------------------------------
post '/create_location' do
  begin
    location = Stripe::Terminal::Location.create(
      display_name: params[:display_name],
      address: params[:address]
    )
  rescue Stripe::StripeError => e
    status 402
    return log_info("Error creating location: #{e.message}")
  end

  content_type :json
  return location.to_json
end
