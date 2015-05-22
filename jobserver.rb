# HTTP Server for Browser-Based MapReduce
#  1) Client is directed to a forms-page; he enters map/reduce code (in javascript!) and input data-files
#  1) Server redirects any client to available jobs
#  ...
#  2) Client executes javascript map/reduce jobs via JavaScript
#  3) Client emits (POST) intermediate results back to job server
#  4) Client is redirected to next available job (map or reduce)
#
# see https://www.igvita.com/2009/03/03/collaborative-map-reduce-in-the-browser/
# and https://github.com/igrigorik/bmr-wordcount/
#
# sample mapper and reducer (for the word-count problem):
# function mapper(data) { var a = []; var b = data.split(/\s+/); for (var i in b) { if (i > 0) { a.push([b[i].replace(/\W+/g, '').toLowerCase(), 1]); } } return a; }
# function reducer(data) { var docs = data.split(/\n/); var newArray = new Array(); for(var i = 0; i < docs.length; i++) { if (docs[i]) { newArray.push(docs[i]); } } if (newArray[0].replace(/\s/g, '')) { var h = {}; h[newArray[0]] = newArray.length - 1; return h; } else { return; } }

require "sinatra"
require "tilt/erb"
require "json"
require "digest/md5"

configure do
  set :chunksize,         500

  set :job_in_progress,   false

  set :mapper,            ""
  set :map_jobs,          []

  set :reducer,           ""
  set :wait_for_maps,     0
  set :interm_results,    Hash.new
  set :reduce_jobs_names, []
  
  set :result,            Hash.new
end

def clear
  # clear all settings and data-folder
    Dir.foreach("data/") {|f| fn = File.join("data/", f); File.delete(fn) if f != '.' && f != '..'}

    settings.job_in_progress = false

    settings.mapper            = ""
    settings.map_jobs          = []

    settings.reducer           = ""
    settings.wait_for_maps     = 0
    settings.interm_results    = Hash.new
    settings.reduce_jobs_names = []

    settings.result            = Hash.new
end


# see http://stackoverflow.com/questions/6150227/ruby-how-to-split-a-file-into-multiple-files-of-a-given-size
def chunker f_in, out_pref, chunksize = 1_073_741_824
  outfilenum = 1
  File.open(f_in,"r") do |fh_in|
    until fh_in.eof?
      File.open("#{out_pref}_#{outfilenum}.txt","w") do |fh_out|
        line = ""
        while fh_out.size <= (chunksize-line.length) && !fh_in.eof?
          line = fh_in.readline
          fh_out << line
        end
      end
      outfilenum += 1
    end
  end
end

def partition(aggregate)
  for partial in aggregate
    if settings.interm_results.has_key?(partial[0])
      settings.interm_results[partial[0]].push partial[1]
    else
      settings.interm_results[partial[0]] = [partial[1]]
      settings.reduce_jobs_names.push partial[0]
    end
  end
end


get "/" do
  redirect "/form"                                     unless settings.job_in_progress
  redirect "/map/#{settings.map_jobs.pop}"             unless settings.map_jobs.empty?
  redirect "/waiting"                                  unless settings.wait_for_maps <= 0
  redirect "/reduce/#{settings.reduce_jobs_names.pop}" unless settings.reduce_jobs_names.empty?
  redirect "/done"
end


get "/form"     do erb :form                                                                         end
get "/map/*"    do erb :map, :locals => {:file => params[:splat].first, :mapper => settings.mapper}; end
get "/waiting"  do erb :wait                                                                         end

get "/reduce/*" do 
  erb :reduce, 
      :locals => {:curr => params[:splat].first, :data => settings.interm_results.delete(params[:splat].first), :reducer => settings.reducer}; 
end

get "/done"     do erb :done,  :locals => {:answer => settings.result}; end


post "/form" do
  if !settings.job_in_progress && params["file"] && params["red"] && params["map"]
    clear
    settings.job_in_progress = true
    
    params["file"].each do |f| 
      fname = "data/" + f[:filename]
      File.open(fname, "w") do |out| 
        out.write(f[:tempfile].read)
      end
      hashed = Digest::MD5.hexdigest(f[:filename])
      chunker fname, "data/" + hashed + "_" , settings.chunksize
      File.delete(fname)
    end
    settings.map_jobs = Dir.glob("data/*.txt") 
    settings.wait_for_maps = settings.map_jobs.length
    
    settings.mapper  = params["map"]
    settings.reducer = params["red"]
  end
  redirect "/"
end

post "/emit/:phase" do
  case params[:phase]
  when "map" then
    partition(JSON.parse(params["job"]))
    settings.wait_for_maps = settings.wait_for_maps - 1
    redirect "/"
  when "reduce" then
    k, v = JSON.parse(params["job"]).first
    settings.result[k] = v
    redirect "/"
  end
end

post "/finishJob" do
  if settings.reduce_jobs_names.length <= 0
    clear
  end
  erb :doneFinal, :locals => {:theData => params["theData"]};
end