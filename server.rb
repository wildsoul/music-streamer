require 'sinatra'
require 'sinatra/browserid'
require 'json'
require 'filemagic'
require 'open3'
require 'net/http'
require 'uri'
require 'nokogiri'
require 'open-uri'
require 'sanitize'
require 'zip/zip'

require './database.rb'

set :sessions, true
# session-hijacking-protection were triggered by ajax-requests
set :protection, except: :session_hijacking
# use server with streaming support (used when transcoding) 
set :server, :puma

helpers do
    include Rack::Utils
    alias_method :h, :escape

    def isAdmin?
        if authorized?
            if Database.new.getOption('admin') == authorized_email
                return true
            end
        end
        return false
    end

    def isGuest?
        if authorized?
            if Database.new.getOption('guest').split(";").include? authorized_email
                return true
            end
        end
        return false
    end
    
    def protected!
        unless isAdmin?
            throw(:halt, [401, "Not authorized\n"])
        end
    end

    def semiProtected!
        unless isAdmin? || isGuest?
            throw(:halt, [401, "Not authorized\n"])
        end
    end

    def firstUse?
        return Database.new.firstUse?
    end
    
    def emptyMediaDB?
        return Database.new.emptyMediaDB?
    end
end

get '/' do
    if ! (isAdmin? || isGuest?)
        erb :login
    else
        db = Database.new
        if db.getOption("mediaDir") == nil
            erb :setDB, :locals => {:mediaDir => nil}
        else
            erb :index, :locals => {:mediaDB => db.getMediaDB}
        end
    end
end

get '/setDB' do
    session[:origin] = back
    erb :setDB, :locals => {:mediaDir => Database.new.getOption("mediaDir")}
end

get '/settings' do
    protected!
    session[:origin] = back
    guests = Database.new.getOption("guest")
    guests = guests.split(";") if guests != nil
    erb :settings, :locals => {:guests => guests}
end

post '/addAdmin' do
    db = Database.new
    if db.firstUse? && ! authorized_email.empty?
        db.setOption('admin', authorized_email)
        redirect to('/')
    else
        'Error adding admin: param missing or admin already set'
    end
end

get '/logout' do
    logout!
    return "Logged out"
end

post '/setOption' do
    protected!
    if params[:name].is_a?(String)
        Database.new.setOption(params[:name], params[:value])
    else
        # we came from the settings, so input is more complex
        params[:name].each do |name, values|
            valueString = ""
            values.each do |key, value|
                valueString+=value + ";"
            end
            Database.new.setOption(name, valueString.chomp(";"))
        end
    end
    origin = session[:origin]
    # when setOption wasn't called first, like with the design, origin is old, so unset it
    session.delete(:origin)
    redirect origin if origin != nil
    redirect back
end

get '/guestInput' do
    protected!
    erb :guestInput, :locals => {:index => params[:index], :mail => ""}
end

post '/updateDB' do
    protected!
    session[:updateTotal] = Database.new.updateDB
    "Done"
end

get '/updateProgress' do
    Database.new.updateProgress.to_s
end

get '/updateTotal' do
    session[:updateTotal].to_s
end

get '/updateDone' do
    Database.new.updateDone.to_s
end

get '/mediaDB' do
    semiProtected!
    erb :mediaDB, :locals => {:mediaDB => Database.new.getMediaDB}
end

get '/tracks' do
    semiProtected!
    tracks = Database.new.getTracks(params[:artist], params[:album]).delete_if{|key, value| key.is_a? Integer}
    JSON(tracks)
end

get '/lyrics' do
    semiProtected!
    track = params[:track].gsub(" ", "_")
    artist = params[:artist].gsub(" ", "_") if params[:artist]

    
    # first, try to get the exact song (https://github.com/cschep/bkkweb/blob/master/lyrics.rb)
    if artist
        uri = URI.parse("http://lyrics.wikia.com/api.php?func=getSong&artist=#{escape(artist)}&song=#{escape(track)}&fmt=xml")
        http = Net::HTTP.new(uri.host, uri.port)
        http_request = Net::HTTP::Get.new(uri.request_uri)
        response = http.request(http_request).body
        lyrics = Nokogiri::XML(response).xpath("/LyricsResult/lyrics").text
        url = Nokogiri::XML(response).xpath("/LyricsResult/url").text
        if ! lyrics.empty?
            songpage = url.gsub("%2F", "/")   # wikia won't find the page if / is encoded, but won't find pages with umlauts if they are encoded
        end
    end

    if ! songpage
        # searching for lyrics (http://stackoverflow.com/questions/1843497/ruby-script-to-grab-lyrics)
        uri = URI.parse("http://lyrics.wikia.com/index.php?action=ajax&rs=getLinkSuggest&format=json&query=#{escape(track)}")
        http = Net::HTTP.new(uri.host, uri.port)
        http_request = Net::HTTP::Get.new(uri.request_uri)
        json = JSON.parse(http.request(http_request).body)
        songpage = "http://lyrics.wikia.com/wiki/" + unescape(json["suggestions"].first) if ! json["suggestions"].empty?
    end

    if songpage
        begin
            lyrics_html = Nokogiri::HTML(open(songpage))
        rescue OpenURI::HTTPError => e
            puts "Error fetching lyrics from #{songpage}: #{e}"
            return "No Lyrics found"
        end
        lyricbox_div = lyrics_html.css('div.lyricbox')
        lyricbox_div.css(".rtMatcher").remove
        puts "send lyrics"
        return Sanitize.clean(lyricbox_div.inner_html.gsub('<br>', "\n"))
    end
    return "No Lyrics found"
end

get '/download' do
    semiProtected!
    tracks = Database.new.getTracks(params[:artist], params[:album]).delete_if{|key, value| key.is_a? Integer}
    filename = (params[:artist] + "_" + params[:album] + ".zip").gsub("/", "_")
    t = Tempfile.new(['temp_zip', '.zip'])
    Zip::ZipOutputStream.open(t.path) do |z|
        tracks.each do |track|
            name = track["title"]
            name += ".mp3" unless name.end_with?(".mp3")
            z.put_next_entry(name)
            z.print(open(Database.new.getPath(track["id"])) {|f| f.read })
        end
    end

    send_file t.path, :type => 'application/zip',
                      :disposition => 'attachment',
                      :filename => filename,
                      :stream => false
    
end

# returns a cover, expects a id of one of the songs of the current album
get '/cover' do
    semiProtected!
    path = Database.new.getPath(params[:id])
    path = File.dirname(path)
    images = Dir[path + "/*.jpg"]
    if (images.size > 1)
        ["folder.jpg", "front.jpg", "large.jpg"].each do |preferredImage|
            index = images.index { |i| i.downcase.include? preferredImage}
            if (index)
                send_file images[index]
            end
        end
    end
    if images.size > 0
        send_file images[0]
    end
end

get %r{/track/([0-9]+)} do |id|
    semiProtected!
    path = Database.new.getPath(id)
    type = FileMagic.new(FileMagic::MAGIC_MIME).file(path)
    
    if type == "application/octet-stream; charset=binary"
        # application/octetstream is the fallback, so the extension is the last hope
        type = "audio/mpeg; charset=binary" if File.extname(path) == ".mp3"
        type = "application/ogg; charset=binary" if File.extname(path) == ".ogg"
    end

    if (type != "application/ogg; charset=binary" &&
        params[:supportOGG] != "" &&
        (!(type == "audio/mpeg; charset=binary" && params[:supportMP3] != "")))
        
        content_type  "application/ogg; charset=binary"

        if request.env["HTTP_RANGE"]
            requestStart = request.env["HTTP_RANGE"].gsub(/bytes=([0-9]*)-/) { $1 }
        end

        size = File.size(path).to_s
        headers "Content-Length" => size, "Last_Modified" => DateTime.now.httpdate #, "Accept-Ranges" => "bytes", "Content-Range" => "bytes #0-#{size}/#{size}"
        stdin, stdout, stderr  = Open3.popen3("ffmpeg", "-loglevel", "quiet",
                                                        "-i", path,
                                                        "-f", "ogg",
                                                        "-y",
                                                        "-acodec", "libvorbis",
                                                        "-aq", "5",
                                                        "-")
        serveTranscodedFile(stdin, stdout, stderr)
        return
    else
        if ((params[:supportMP3] != "" && type != "audio/mpeg; charset=binary") &&
            (!(params[:supportOGG] != "" && type == "application/ogg; charset=binary")))

            content_type  "application/ogg; charset=binary"
            headers "Content-Length" => File.size(path).to_s, "Last_Modified" => DateTime.now.httpdate
            stdin, stdout, stderr  = Open3.popen3("ffmpeg", "-loglevel", "quiet",
                                                            "-i", path,
                                                            "-f", "mp3",
                                                            "-y",
                                                            "-ab", "160k",
                                                            "-")
            serveTranscodedFile(stdin, stdout, stderr)
            return
        end
    end

    content_type type
    response['Cache-Control'] = "public, max-age=31536000"   # NOTE: chrome doesn't cache the audio regardless
    send_file path, :type => type, :last_modified => DateTime.now.httpdate
end

def serveTranscodedFile(stdin, stdout, stderr)
    stream do |out|
        begin
            loop do
                IO.select([stdout]) 
                out << stdout.read_nonblock(8192)
            end
        rescue Errno::EAGAIN
            retry
        rescue EOFError            
            stdin.close 
            stdout.close
            stderr.close
        end
    end
end
