require 'sinatra/base'
require 'sinatra/contrib'
require 'pg'
require 'tilt/erubis'
require 'erubis'
require 'oj'
require 'httpclient'
require 'openssl'
require 'redis'
require 'redis/connection/hiredis'
require 'concurrent'
require 'expeditor'
require 'time'

module Isucon5f
  module TimeWithoutZone
    def to_s
      strftime("%F %H:%M:%S")
    end
  end
  ::Time.prepend TimeWithoutZone
end

class Isucon5f::WebApp < Sinatra::Base
  use Rack::Session::Cookie, secret: (ENV['ISUCON5_SESSION_SECRET'] || 'tonymoris')
  set :erb, escape_html: true
  set :public_folder, File.expand_path('../../static', __FILE__)

  SALT_CHARS = [('a'..'z'),('A'..'Z'),('0'..'9')].map(&:to_a).reduce(&:+)

  Endpoint = Struct.new(:token_type, :token_key, :uri)

  ENDPOINTS = {
    'ken2' => Endpoint.new(nil, nil, 'http://api.five-final.isucon.net:8080/'),
    'surname' => Endpoint.new(nil, nil, 'http://api.five-final.isucon.net:8081/surname'),
    'givenname' => Endpoint.new(nil, nil, 'http://api.five-final.isucon.net:8081/givenname'),
    'tenki' => Endpoint.new('param', 'zipcode', 'http://api.five-final.isucon.net:8988/'),
    'perfectsec' => Endpoint.new('header', 'X-PERFECT-SECURITY-TOKEN', 'https://api.five-final.isucon.net:8443/tokens'),
    'perfectsec_attacked' => Endpoint.new('header', 'X-PERFECT-SECURITY-TOKEN', 'https://api.five-final.isucon.net:8443/attacked_list'),
  }

  CLIENT = HTTPClient.new
  CLIENT.ssl_config.verify_mode = OpenSSL::SSL::VERIFY_NONE

  EXPEDITOR_SERVICE = Expeditor::Service.new(
      executor: Concurrent::ThreadPoolExecutor.new(
          min_threads: 5,
          max_threads: 5,
          max_queue: 0,
      )
  )
  # redis is thread-safe
  REDIS_CLIENT = Redis.new(
    host: ENV['REDIS_HOST'] || 'localhost',
    port: (ENV['REDIS_PORT'] || 6379).to_i,
  )

  USERJS = {
      'micro'    => 'var AIR_ISU_REFRESH_INTERVAL = 30000;',
      'small'    => 'var AIR_ISU_REFRESH_INTERVAL = 30000;',
      'standard' => 'var AIR_ISU_REFRESH_INTERVAL = 20000;',
      'premium'  => 'var AIR_ISU_REFRESH_INTERVAL = 10000;',
  }

  helpers do
    def config
      @config ||= {
        db: {
          host: ENV['ISUCON5_DB_HOST'] || 'localhost',
          port: ENV['ISUCON5_DB_PORT'] && ENV['ISUCON5_DB_PORT'].to_i,
          username: ENV['ISUCON5_DB_USER'] || 'isucon',
          password: ENV['ISUCON5_DB_PASSWORD'],
          database: ENV['ISUCON5_DB_NAME'] || 'isucon5f',
        },
      }
    end

    def db
      return Thread.current[:isucon5_db] if Thread.current[:isucon5_db]
      conn = PG.connect(
        host: config[:db][:host],
        port: config[:db][:port],
        user: config[:db][:username],
        password: config[:db][:password],
        dbname: config[:db][:database],
        connect_timeout: 3600
      )
      Thread.current[:isucon5_db] = conn
      conn
    end

    def authenticate(email, password)
      user_id = REDIS_CLIENT.get("email:#{email}:#{password}")
      unless user_id
        return
      end
      h = REDIS_CLIENT.hgetall("user:#{user_id}")
      user = {id: h['id'].to_i, email: h['email'], grade: h['grade']}
      session[:user_id] = user[:id]
      user
    end

    def current_user
      return @user if @user
      return nil unless session[:user_id]
      h = REDIS_CLIENT.hgetall("user:#{session[:user_id]}")
      @user = nil
      if h
        @user = {id: h['id'].to_i, email: h['email'], grade: h['grade']}
      else
        session.clear
        nil
      end
    end

    def save_user(id, email, password, grade)
      key = "user:#{id}"
      REDIS_CLIENT.hset(key, 'id', id)
      REDIS_CLIENT.hset(key, 'email', email)
      REDIS_CLIENT.hset(key, 'grade', grade)
      REDIS_CLIENT.set("email:#{email}:#{password}", id)
    end

    def load_users
      last_id = 0
      loop do
        db.exec_params('SELECT id, email, grade FROM users WHERE id > $1 ORDER BY id LIMIT 2000', [last_id]) do |result|
          if result.cmd_tuples == 0
            REDIS_CLIENT.set("last_user_id", last_id)
            return
          end
          result.each do |tuple|
            id = tuple['id'].to_i
            save_user(id, tuple['email'], tuple['email'].split('@', 2)[0], tuple['grade'])
            last_id = id
          end
        end
      end
    end

    def put_subscriptions(user_id, arg)
      REDIS_CLIENT.set("subscriptions:#{user_id}", Oj.dump(arg))
    end

    def fetch_subscriptions(user_id)
      json = REDIS_CLIENT.get("subscriptions:#{user_id}")
      unless json
        raise "No subscriptions for #{user_id}"
      end
      Oj.load(json)
    end
  end

  get '/signup' do
    session.clear
    erb :signup
  end

  post '/signup' do
    email, password, grade = params['email'], params['password'], params['grade']
    user_id = REDIS_CLIENT.get('last_user_id').to_i + 1
    save_user(user_id, email, password, grade)
    REDIS_CLIENT.incr('last_user_id')
    default_arg = {}
    put_subscriptions(user_id, default_arg)
    redirect '/login'
  end

  post '/cancel' do
    redirect '/signup'
  end

  get '/login' do
    session.clear
    erb :login
  end

  post '/login' do
    authenticate params['email'], params['password']
    halt 403 unless current_user
    redirect '/'
  end

  get '/logout' do
    session.clear
    redirect '/login'
  end

  get '/' do
    unless current_user
      return redirect '/login'
    end
    erb :main, locals: {user: current_user}
  end

  get '/user.js' do
    halt 403 unless current_user

    content_type 'application/javascript'
    USERJS[current_user[:grade]]
  end

  get '/modify' do
    user = current_user
    halt 403 unless user
    erb :modify, locals: {user: user}
  end

  post '/modify' do
    user = current_user
    halt 403 unless user

    service = params["service"]
    token = params.has_key?("token") ? params["token"].strip : nil
    keys = params.has_key?("keys") ? params["keys"].strip.split(/\s+/) : nil
    param_name = params.has_key?("param_name") ? params["param_name"].strip : nil
    param_value = params.has_key?("param_value") ? params["param_value"].strip : nil

    arg = fetch_subscriptions(user[:id])
    arg[service] ||= {}
    arg[service]['token'] = token if token
    arg[service]['keys'] = keys if keys
    if param_name && param_value
      arg[service]['params'] ||= {}
      arg[service]['params'][param_name] = param_value
    end
    put_subscriptions(user[:id], arg)

    redirect '/modify'
  end

  def fetch_api(uri, headers, params)
    #t0 = Time.now
    res = CLIENT.get_content(uri, params, headers)
    #puts "#{Time.now - t0} - #{uri} - #{res}"
    Oj.load(res)
  end

  def cache_json(cache_key, validator = nil)
    cached = REDIS_CLIENT.get(cache_key)
    if cached
      data = Oj.load(cached)

      valid = true
      if validator
        unless validator.call(data)
          valid = false
        end
      end

      if valid
        return data
      end
    end

    data = yield
    REDIS_CLIENT.set(cache_key, Oj.dump(data))
    data
  end

  def fetch_api_with_cache(service, uri, headers, params)
    case service
    when 'ken2'
      cache_key = "ken2:#{params['zipcode']}"
      cache_json(cache_key) do
        fetch_api(uri, headers, params)
      end
    when 'surname', 'givenname'
      cache_key = "#{service}:#{params['q']}"
      cache_json(cache_key) do
        fetch_api(uri, headers, params)
      end
    when 'tenki'
      cache_key = "#{service}:#{params['zipcode']}"
      validator = proc do |data|
        # TODO: Time#parse is maybe slow
        (Time.now.to_f - Time.parse(data['date']).to_f) < 2.8
      end
      cache_json(cache_key, validator) do
        fetch_api(uri, headers, params)
      end
    when 'perfectsec_attacked'
      cache_key = "#{service}:#{headers['X-PERFECT-SECURITY-TOKEN']}"
      validator = proc do |data|
        (Time.now.to_f - data['updated_at'].to_f) < 20.0
      end
      cache_json(cache_key, validator) do
        fetch_api(uri, headers, params)
      end
    else
      fetch_api(uri, headers, params)
    end
  end

  get '/data' do
    unless user = current_user
      halt 403
    end

    arg = fetch_subscriptions(user[:id])

    data = []

    commands = []

    arg.each_pair do |service_orig, conf|
      service =
          if service_orig == 'ken'.freeze
            'ken2'
          else
            service_orig
          end
      endpoint = ENDPOINTS.fetch(service)

      headers = {}
      params = (conf['params'] && conf['params'].dup) || {}
      case endpoint.token_type
        when 'header' then headers[endpoint.token_key] = conf['token']
        when 'param' then params[endpoint.token_key] = conf['token']
      end
      if service_orig == 'ken'.freeze
        params['zipcode'] = conf['keys'][0]
      end

      if endpoint.uri.match(/^https:/)
        # HTTPSは 429 Too Many Requestsがくるので並列化しない
        data << {"service" => service_orig, "data" => fetch_api_with_cache(service, endpoint.uri, headers, params)}
      else
        # HTTPは並列化する
        command = Expeditor::Command.new(service: EXPEDITOR_SERVICE) do
          begin
           {"service" => service_orig, "data" => fetch_api_with_cache(service, endpoint.uri, headers, params)}
          rescue => e
            STDERR.puts(e)
            STDERR.puts(e.backtrace.join("\n"))
            raise e
          end
        end
        command.start
        commands << command
      end
    end

    commands.each do |c|
      data << c.get
    end

    json data
  end

  get '/initialize' do
    file = File.expand_path("../../sql/initialize.sql", __FILE__)
    $stderr.puts "#{Time.now} Initializing DB..."
    system("psql", "-f", file, "isucon5f")

    $stderr.puts "#{Time.now} Flushing Redis..."
    REDIS_CLIENT.flushdb
    $stderr.puts "#{Time.now} Importing subscriptions"
    db.exec_params('SELECT user_id,arg FROM subscriptions').values.each do |user_id, arg|
      put_subscriptions(user_id, Oj.load(arg))
    end
    $stderr.puts "#{Time.now} Importing users"
    load_users

    $stderr.puts "#{Time.now} Finish"
    'ok'
  end
end
