require 'net/http'
require 'json'
require 'dotenv/load'
require 'milkman'
require 'active_support/time'

DEFAULT_TIME_ZONE = 'Europe/Warsaw'
TRMNL_PAYLOAD_LIMIT = 2048
MAX_TASKS_TO_DISPLAY = 17

###### methods #############
def format_date(due_date)
  if due_date.nil? or due_date.empty?
    return ''
  end

  #conversion needed due to rtm native format
  #for example: 2025-03-22T23:00:00Z should be 2025-03-23
  Time.parse(due_date)
      .in_time_zone(DEFAULT_TIME_ZONE)
      .to_date
      .strftime("%Y-%m-%d")
end

def get_rtm_data(list_name)
  client = Milkman::Client.new(api_key: ENV['RTM_API_KEY'],
                               shared_secret: ENV['RTM_SHARED_SECRET'],
                               auth_token: ENV['RTM_AUTH_TOKEN'])

  lists_response = client.get 'rtm.lists.getList'

  lists = lists_response['rsp']['lists']['list']

  list_names = lists.to_h { |list| [list['id'], list['name']] }

  tasks_response = client.get("rtm.tasks.getList",
                              filter: "status:incomplete AND list:#{list_name}")

  tasks_formatted = tasks_response['rsp']['tasks']['list'].flat_map { |list|
    list_id = list['id']
    list_name = list_names[list_id]
    list['taskseries'].map { |task|
      due_date = task['task'][0]['due']

      tags = task['tags'].empty? ? [] : task['tags']['tag']

      {name: task['name'],
       due: format_date(due_date),
       tags: tags,
       list: list_name
      }
    }
  }.sort_by { |task|
    [task[:due].empty? ? '9999-12-31' : task[:due], task[:name]]
  }

  limited_array = tasks_formatted.take(MAX_TASKS_TO_DISPLAY)

  {list: list_name,
   tasks: limited_array,
   surplus_tasks: tasks_formatted.size - limited_array.size}
rescue StandardError => e
  puts "Error: #{e.message}"
  raise
end

def send_to_trmnl(data_payload)
  trmnl_webhook_url = "https://usetrmnl.com/api/custom_plugins/#{ENV['TRMNL_PLUGIN_ID']}"

  puts('Send data to trmnl webhook')
  uri = URI(trmnl_webhook_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  headers = {
    'Content-Type' => 'application/json',
    'Authorization' => "Bearer #{ENV['TRMNL_API_KEY']}"
  }

  request = Net::HTTP::Post.new(uri.path, headers)
  body = { merge_variables: data_payload }.to_json

  puts body

  if body.bytesize > TRMNL_PAYLOAD_LIMIT
    raise "Request body is too large (#{body.bytesize} bytes, limit: #{TRMNL_PAYLOAD_LIMIT} bytes)"
  else
    puts "Request body size: (#{body.bytesize} bytes)"
  end

  request.body = body
  response = http.request(request)

  if response.is_a?(Net::HTTPSuccess)
    current_timestamp = DateTime.now.iso8601
    puts "Tasks sent successfully to TRMNL at #{current_timestamp}"
  else
    puts "Error: #{response.body}"
  end
rescue StandardError => e
  puts "Error: #{e.message}"
  raise
end

############# execution #########

task_data = get_rtm_data(ENV['RTM_LIST'])
puts task_data
send_to_trmnl(task_data)
