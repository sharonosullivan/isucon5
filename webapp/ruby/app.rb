require 'sinatra/base'
require 'sinatra/contrib'
require 'pg'
require 'tilt/erubis'
require 'erubis'
require 'json' # ojのほうがはやそう
require 'httpclient'
require 'openssl'
require 'redis'
require 'concurrent'
require 'expeditor'

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

  CLIENT = HTTPClient.new
  CLIENT.ssl_config.verify_mode = OpenSSL::SSL::VERIFY_NONE


  EXPEDITOR_SERVICE = Expeditor::Service.new(
      executor: Concurrent::ThreadPoolExecutor.new(
          min_threads: 5,
          max_threads: 5,
          max_queue: 0,
      )
  )

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

    def redis
      # redis is thread-safe
      @redis ||= Redis.new(
        host: 'localhost',
        port: 6379,
      )
    end

    def authenticate(email, password)
      query = <<SQL
SELECT id, email, grade FROM users WHERE email=$1 AND passhash=digest(salt || $2, 'sha512')
SQL
      user = nil
      db.exec_params(query, [email, password]) do |result|
        result.each do |tuple|
          user = {id: tuple['id'].to_i, email: tuple['email'], grade: tuple['grade']}
        end
      end
      session[:user_id] = user[:id] if user
      user
    end

    def current_user
      return @user if @user
      return nil unless session[:user_id]
      @user = nil
      db.exec_params('SELECT id,email,grade FROM users WHERE id=$1', [session[:user_id]]) do |r|
        r.each do |tuple|
          @user = {id: tuple['id'].to_i, email: tuple['email'], grade: tuple['grade']}
        end
      end
      session.clear unless @user
      @user
    end

    def generate_salt
      salt = ''
      32.times do
        salt << SALT_CHARS[rand(SALT_CHARS.size)]
      end
      salt
    end
  end

  get '/signup' do
    session.clear
    erb :signup
  end

  post '/signup' do
    email, password, grade = params['email'], params['password'], params['grade']
    salt = generate_salt
    insert_user_query = <<SQL
INSERT INTO users (email,salt,passhash,grade) VALUES ($1,$2,digest($3 || $4, 'sha512'),$5) RETURNING id
SQL
    default_arg = {}
    insert_subscription_query = <<SQL
INSERT INTO subscriptions (user_id,arg) VALUES ($1,$2)
SQL
    db.transaction do |conn|
      user_id = conn.exec_params(insert_user_query, [email,salt,salt,password,grade]).values.first.first
      conn.exec_params(insert_subscription_query, [user_id, default_arg.to_json])
    end
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
    erb :userjs, content_type: 'application/javascript', locals: {grade: current_user[:grade]}
  end

  get '/modify' do
    user = current_user
    halt 403 unless user

    # subscriptionsはRedisに突っ込めそう
    query = <<SQL
SELECT arg FROM subscriptions WHERE user_id=$1
SQL
    arg = db.exec_params(query, [user[:id]]).values.first[0]
    erb :modify, locals: {user: user, arg: arg}
  end

  post '/modify' do
    user = current_user
    halt 403 unless user

    service = params["service"]
    token = params.has_key?("token") ? params["token"].strip : nil
    keys = params.has_key?("keys") ? params["keys"].strip.split(/\s+/) : nil
    param_name = params.has_key?("param_name") ? params["param_name"].strip : nil
    param_value = params.has_key?("param_value") ? params["param_value"].strip : nil
    # select ... for updateは行ロックする
    select_query = <<SQL
SELECT arg FROM subscriptions WHERE user_id=$1 FOR UPDATE
SQL
    update_query = <<SQL
UPDATE subscriptions SET arg=$1 WHERE user_id=$2
SQL
    db.transaction do |conn|
      arg_json = conn.exec_params(select_query, [user[:id]]).values.first[0]
      arg = JSON.parse(arg_json)
      arg[service] ||= {}
      arg[service]['token'] = token if token
      arg[service]['keys'] = keys if keys
      if param_name && param_value
        arg[service]['params'] ||= {}
        arg[service]['params'][param_name] = param_value
      end
      conn.exec_params(update_query, [arg.to_json, user[:id]])
    end
    redirect '/modify'
  end

  def fetch_api(method, uri, headers, params)
    fetcher = case method
              when 'GET' then CLIENT.method(:get_content)
              when 'POST' then CLIENT.method(:post_content)
              else
                raise "unknown method #{method}"
              end
    res = fetcher.call(uri, params, headers)
    JSON.parse(res)
  end

  def fetch_api_with_cache(service, method, uri, headers, params)
    case service
    when 'ken2'
      cache_key = "ken2:#{params['zipcode']}"
      data = redis.get(cache_key)
      if data
        JSON.parse(data)
      else
        data = fetch_api(method, uri, headers, params)
        redis.set(cache_key, JSON.dump(data))
        data
      end
    else
      fetch_api(method, uri, headers, params)
    end
  end

  get '/data' do
    unless user = current_user
      halt 403
    end

    # user_id=json という構造なのでRedisでよさそう
    # json例: {"ken":{"keys":["9593941"]},"ken2":{"params":{"zipcode":"4928178"}},"surname":{"params":{"q":"海老"}},"givenname":{"params":{"q":"さくの>      じょう"}},"tenki":{"token":"9593941"}}
    arg_json = db.exec_params("SELECT arg FROM subscriptions WHERE user_id=$1", [user[:id]]).values.first[0]
    arg = JSON.parse(arg_json)

    commands = []

    arg.each_pair do |service, conf|
      command = Expeditor::Command.new(service: EXPEDITOR_SERVICE, timeout: 5) do
        puts "XXXX #{service} #{conf}"
        begin
          row = db.exec_params("SELECT meth, token_type, token_key, uri FROM endpoints WHERE service=$1", [service]).values.first
          method, token_type, token_key, uri_template = row
          p row
          headers = {}
          params = (conf['params'] && conf['params'].dup) || {}
          case token_type
            when 'header' then headers[token_key] = conf['token']
            when 'param' then params[token_key] = conf['token']
          end
          uri = sprintf(uri_template, *conf['keys'])
           {"service" => service, "data" => fetch_api_with_cache(service, method, uri, headers, params)}
        rescue StandardError => e
          # Expeditor::DependencyErrorはエラーをもってないっぽいのでここで
          puts e
          puts e.backtrace.join("\n")
          raise e
        end
      end
      commands << command
    end

    master = Expeditor::Command.new(timeout: 10, dependencies: [commands[0]], service: EXPEDITOR_SERVICE) do |result|
        result
    end
    master.start
    json master.get
  end

  get '/initialize' do
    file = File.expand_path("../../sql/initialize.sql", __FILE__)
    system("psql", "-f", file, "isucon5f")
  end
end
