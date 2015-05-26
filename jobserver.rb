#  Samuel Bald, Michael Iannelli, Antonio Moretti
#
#  HTTP-Server for Browser-Based MapReduce 
#  (coded in Sinatra, a Ruby-based DSL Web-Application Library)
#
#  Overview of Protocol and Operation:
#  1) Clients are directed to application welcome-page where map/reduce code (in javascript!) and input data-files may be entered. 
#     A distinguished client then submits a MapReduce HTTP-request for his provided information.
#  2) Server redirects polling clients to available map-jobs. A map-job is executed in the client browser via HTML/Javascript and
#     the intermediate result is emitted to the server via a HTTP POST.
#  3) Server signals polling clients to "wait" (i.e., retry after a short time-out) until all map-jobs have returned before 
#     sending reduce-jobs.
#  4) Server redirects polling clients to available reduce-jobs. A reduce-job is executed in the client browser via 
#     HTML/Javascript and the final (partial) result is emitted to the server via a HTTP POST.
#  5) Server displays final MapReduce results in the browsers of all polling clients, and clears all stored data; the server is
#     then ready to service another MapReduce.
#
#  Note: The idea of the basic skeleton for this project was culled from the following project:
#    https://github.com/igrigorik/bmr-wordcount/
#  For further description and motivation see: 
#    https://www.igvita.com/2009/03/03/collaborative-map-reduce-in-the-browser/
#  
# Sample map/reduce code in Javascript forthe word-frequency analysis of a document:
# function map(data) { var a = []; var b = data.split(/\s+/); for (var i in b) { if (i > 0) { a.push([b[i].replace(/\W+/g, '').toLowerCase(), 1]); } } return a; }
# function reduce(data) { var docs = data.split(/\n/); var newArray = new Array(); for(var i = 0; i < docs.length; i++) { if (docs[i]) { newArray.push(docs[i]); } } if (newArray[0].replace(/\s/g, '')) { var h = {}; h[newArray[0]] = newArray.length - 1; return h; } else { return; } }


require "sinatra"
require "tilt/erb"
require "json"
require "digest/md5"


#################
# Configuration #
#################


# set up server global variables and data structures
configure do
  set :chunksize,         500       # size of map-jobs in bytes (i.e. file-size)

  set :job_in_progress,   false

  set :mapper,            ""        # map-code
  set :map_jobs,          []

  set :reducer,           ""        # reduce-code
  set :wait_for_maps,     0
  set :interm_results,    Hash.new
  set :reduce_jobs_names, []        # list of intermediate keys
  
  set :result,            Hash.new  # final result
end


####################
# Helper Functions #
####################


# reset all server settings and delete all stored data
def clear
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

# Split the input files into "chunks" of a certain size in bytes
# Code taken from:
#   http://stackoverflow.com/questions/6150227/ruby-how-to-split-a-file-into-multiple-files-of-a-given-size
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

# group all of the intermediate results returned by the map-jobs on their keys
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


#####################
# HTTP-based Server #
#####################


# phase-based redirection
get "/" do
  redirect "/form"                                     unless settings.job_in_progress
  redirect "/map/#{settings.map_jobs.pop}"             unless settings.map_jobs.empty?
  redirect "/waiting"                                  unless settings.wait_for_maps <= 0
  redirect "/reduce/#{settings.reduce_jobs_names.pop}" unless settings.reduce_jobs_names.empty?
  redirect "/done"
end

# construct relevant HTML page for client using erb (embedded ruby) templating and direct client accordingly.
# note that parameters are used to pass clients the relevant map/reduce job-data

get "/form"     do erb :form                                                                         end
get "/map/*"    do erb :map, :locals => {:file => params[:splat].first, :mapper => settings.mapper}; end
get "/waiting"  do erb :wait                                                                         end

get "/reduce/*" do 
  erb :reduce, 
      :locals => {:curr => params[:splat].first, :data => settings.interm_results.delete(params[:splat].first), :reducer => settings.reducer}; 
end

get "/done"     do erb :done,  :locals => {:answer => settings.result}; end

# reactions to client POST messages

# react to client MapReduce submit request
post "/form" do
  # if no MapReduce currently running and the user filled out forms
  if !settings.job_in_progress && params["file"] && params["red"] && params["map"]
    clear
    settings.job_in_progress = true
    
    # split input into chunks
    params["file"].each do |f| 
      fname = "data/" + f[:filename]
      File.open(fname, "w") do |out| 
        out.write(f[:tempfile].read)
      end
      hashed = Digest::MD5.hexdigest(f[:filename])
      chunker fname, "data/" + hashed + "_" , settings.chunksize
      File.delete(fname)
    end
    # map-jobs are the file chunks
    settings.map_jobs = Dir.glob("data/*.txt") 
    settings.wait_for_maps = settings.map_jobs.length
    
    settings.mapper  = params["map"]
    settings.reducer = params["red"]
  end
  redirect "/"
end

# client returns data from map/reduce job
post "/emit/:phase" do
  case params[:phase]
  when "map" then
    partition(JSON.parse(params["job"]))  # register intermediate result to relevant key
    settings.wait_for_maps = settings.wait_for_maps - 1
    redirect "/"
  when "reduce" then
    k, v = JSON.parse(params["job"]).first
    settings.result[k] = v  # register final (partial) result
    redirect "/"
  end
end

# client finished polling; diplay prettified final results
post "/finishJob" do
  if settings.reduce_jobs_names.length <= 0
    clear
  end
  erb :doneFinal, :locals => {:theData => params["theData"]};
end
