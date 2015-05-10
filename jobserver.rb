# HTTP Server for Browser-Based MapReduce
#
#  1) Server redirects the client to available jobs
#  2) Client executes javascript map/reduce jobs via JavaScript
#  3) Client emits (POST) intermediate results back to job server
#  4) Client is redirected to next available job (map or reduce)

require "sinatra"
require "json"
require "tilt/erb"
require "digest/md5"

configure do
  # assume for now that the data has already been chunkified into separate files; later we can implement rudimentary
  # chunkifying, e.g., partitioning a given file on a given size limit (say in MB), or partitioning multiple files thusly
  set :map_jobs,          Dir.glob("data/*.txt") 
  set :reduce_jobs_names, []
  set :reduce_jobs,       Hash.new
  set :result,            Hash.new
end

def partition(aggregate)
  grouped = Hash.new
  for partial in aggregate
    if grouped.has_key?(partial[0])
      grouped[partial[0]].push partial[1]
    else
      grouped[partial[0]] = [partial[1]]
    end
  end
  grouped
end

def hasher(list)
  Digest::MD5.hexdigest(list.join("|separator|"))
end

get "/" do
  redirect "/map/#{settings.map_jobs.pop}"             unless settings.map_jobs.empty?
  redirect "/reduce/#{settings.reduce_jobs_names.pop}" unless settings.reduce_jobs_names.empty?
  redirect "/done"
end

get "/map/*"    do erb :map,    :locals => {:file   => params[:splat].first};                               end
get "/reduce/*" do erb :reduce, :locals => {:data   => settings.reduce_jobs.delete(params[:splat].first)};  end
get "/done"     do erb :done,   :locals => {:answer => settings.result};                                    end

post "/emit/:phase" do
  case params[:phase]
  when "reduce" then
  	unreduced = partition(JSON.parse(params["aggregate"]))
    for k, v in unreduced
      current_hash_key = hasher([k] + v)
  	  settings.reduce_jobs_names.push current_hash_key
      settings.reduce_jobs[current_hash_key] = [k] + v
    end
    redirect "/"
  when "partial" then
  	settings.result = settings.result.merge(JSON.parse(params["sum"])){|key, oldVal, newVal| oldVal + newVal}
    redirect "/"
  end
end
