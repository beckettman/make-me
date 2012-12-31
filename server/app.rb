#!/usr/bin/env ruby

require 'bundler'
Bundler.require
require 'timeout'
require_relative 'lib/download'

module MakeMe
  class App < Sinatra::Base
    PID_FILE  = File.join('tmp', 'make.pid')
    LOG_FILE  = File.join('tmp', 'make.log')
    FETCH_MODEL_FILE = File.join('data', 'fetch.stl')
    CURRENT_MODEL_FILE = File.join('data', 'print.stl')

    ## Config
    set :static, true
    enable :method_override

    basic_auth do
      realm 'The 3rd Dimension'
      username ENV['MAKE_ME_USERNAME'] || 'hubot'
      password ENV['MAKE_ME_PASSWORD'] || 'isalive'
    end

    helpers do
      def progress
        progress = 0
        if File.exists?(LOG_FILE)
          File.readlines(LOG_FILE).each do |line|
            matches = line.strip.scan /Sent \d+\/\d+ \[(\d+)%\]/
            matches.length > 0 && progress = matches[0][0].to_i
          end
        end
        progress
      end
    end

    get '/' do
      @current_log = File.read(LOG_FILE) if File.exists?(LOG_FILE)
      erb :index
    end

    get '/current_model' do
      if File.exist?(CURRENT_MODEL_FILE)
        content_type "application/sla"
        send_file CURRENT_MODEL_FILE
      else
        status 404
        "not found"
      end
    end

    get '/photo' do
      imagesnap = File.join(File.dirname(__FILE__), '..', 'vendor', 'imagesnap', 'imagesnap')

      out_name = 'snap_' + Time.now.to_i.to_s + ".jpg"
      out_dir = File.join(File.dirname(__FILE__), "public")

      Process.wait Process.spawn(imagesnap, File.join(out_dir, out_name))

      redirect out_name
    end

    ## Routes/Authed
    post '/print' do
      require_basic_auth
      if locked?
        halt 423, lock_data
      else
        lock!
      end

      args = Yajl::Parser.new(:symbolize_keys => true).parse request.body.read

      stl_urls      = [*args[:url]]
      count         = (args[:count]   || 1).to_i
      scale         = (args[:scale]   || 1.0).to_f
      grue_conf     = (args[:config]  || 'default')
      slice_quality = (args[:quality] || 'medium')
      density       = (args[:density] || 0.05).to_f

      # Fetch all of the inputs to temp files
      inputs = MakeMe::Download.new(stl_urls, FETCH_MODEL_FILE).fetch

      # Duplicate the requested number of times.
      inputs = inputs * count

      # Normalize the download
      stl_file = CURRENT_MODEL_FILE
      bounds = {
        :L => (ENV['MAKE_ME_MAX_X'] || 285).to_f.to_s,
        :W => (ENV['MAKE_ME_MAX_Y'] || 153).to_f.to_s,
        :H => (ENV['MAKE_ME_MAX_Z'] || 155).to_f.to_s,
      }
      normalize = ['./vendor/stltwalker/stltwalker', '-p',
                   '-L', bounds[:L], '-W', bounds[:W], '-H', bounds[:H],
                   '-o', stl_file, "--scale=#{scale}", *inputs]
      stl_file = CURRENT_MODEL_FILE
      pid = Process.spawn(*normalize, :err => :out, :out => [LOG_FILE, "w"])
      _pid, status = Process.wait2 pid
      halt 409, "Model normalize failed."  unless status.exitstatus == 0

      # Print the normalized STL
      make_params = [ "GRUE_CONFIG=#{grue_conf}",
                      "QUALITY=#{slice_quality}",
                      "DENSITY=#{density}"]

      make_stl    = [ "make", *make_params,
                      "#{File.dirname(stl_file)}/#{File.basename(stl_file, '.stl')};",
                      "rm #{PID_FILE}"].join(" ")

      # Kick off the print, if it runs for >5 seconds, it's unlikely it failed
      # during slicing
      begin
        pid = Process.spawn(make_stl, :err => :out, :out => [LOG_FILE, "a"])
        File.open(PID_FILE, 'w') { |f| f.write pid }
        Timeout::timeout(5) do
          Process.wait pid
          status 500
          "Process died within 5 seconds with exit status #{$?.exitstatus}"
        end
      rescue Timeout::Error
        status 200
        "Looks like it's printing correctly"
      end
    end

    get '/log' do
      content_type :text
      File.read(LOG_FILE) if File.exists?(LOG_FILE)
    end
  end
end

require_relative 'app/lock'
