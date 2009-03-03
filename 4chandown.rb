#!/usr/bin/env ruby
# encoding: UTF-8

require 'time'
require 'thread'
require 'net/http'
require 'fileutils'

# %s is the thread number. Not %i because of the usage notice.
DEFAULT_OUTPUT_DIRECTORY = "~/Pictures/4chan/%s"

# This is a fix for what I think is a bug. The `while` condition is the only
# change. Source: net/protocol.rb.
# 
# You can remove this, but you may see the following error. No other adverse
# effects should appear.
# 
# …/net/protocol.rb:89:in `read': undefined method `size' for nil:NilClass (NoMethodError)
class Net::BufferedIO
  def read(len, dest = '', ignore_eof = false)
    LOG "reading #{len} bytes..."
    read_bytes = 0
    begin
      while @rbuf.size < len
        dest << (s = rbuf_consume(@rbuf.size))
        read_bytes += s.size
        rbuf_fill
      end
      dest << (s = rbuf_consume(len - read_bytes))
      read_bytes += s.size
    rescue EOFError
      raise unless ignore_eof
    end
    LOG "read #{read_bytes} bytes"
    dest
  end
end

# Currently only supports /b/; support for other boards/sites should be fairly trivial.
class FourChan
  IMAGE_PATTERN =
    %r{<span class="filesize">File :<a href="(http://img\.4chan\.org/b/src/(\d+\.\w+)#{
       })" [^>]+>\d+\.\w+</a>\-\(.+?, \d+x\d+, <span title="([^"]+)\.\w+">.+?</span>\)}
  FIRST_POST_TIME_PATTERN =
    %r{<span class="postername">.+?</span> (\d\d/\d\d/\d\d\(\w+\)\d\d:\d\d:\d\d)}
  
  class Thread404dError < StandardError; end
  
  def initialize thread_number, directory
    @directory        = directory
    @thread_number    = thread_number
    @threads          = []
    @downloaded_files = Dir.entries(@directory).reject { |f| f[0] == ?. }
    @thread_url       = URI.parse "http://img.4chan.org/b/res/#@thread_number.html"
    
    #DING-DING-DING-DING-DING-DING-DING
    @log_semaphore          = Mutex.new
    @thread_array_semaphore = Mutex.new
    # I choo-choo-choose you! <(^___^)>
    
    # The need for force_ may be bug, or my misunderstanding of 1.9.
    @downloaded_files.map! { |f| f.force_encoding Encoding::UTF_8 } if RUBY_VERSION =~ /^1\.9/
  end
  
  # Convenience method.
  def self.leech *args
    new(*args).leech
  end
  
  # Returns true if there's any possibility there's a new image up, based on
  # the Last-Modified HTTP header.
  def has_new?
    return true if @last_post_time.nil?
    
    Net::HTTP.start @thread_url.host, 80 do |http|
      response = http.head(@thread_url.path)
      raise Thread404dError if response.code.to_i == 404 # .to_i because net/http is retarded.
      Time.parse(response['Last-Modified']) > @last_post_time
    end
  end
  
  # Yields the URL and intended file name of any undownloaded images in the
  # thread. It will yield the first time long before the entire HTML document
  # has been downloaded. Through BLOOD, SWEAT AND TEARS, that's how!
  def new_images &block
    Net::HTTP.start @thread_url.host, 80 do |http|
      # Net::HTTP#request with block does not guarantee that the fragment ends
      # at newlines. This buffers the last line of the previous fragment.
      buffer = ""
      
      # LOOK WHAT I HAVE TO GO THROUGH TO GET FRAGMENTED DOWNLOAD WHILE HAVING
      # ACCESS TO THE FRIGGIN’ HEADERS‼
      http.request(Net::HTTP::Get.new(@thread_url.path)) do |response|
        raise Thread404dError if response.code.to_i == 404
        @last_post_time = Time.parse response['Last-Modified']
        
        response.read_body do |fragment|
          next unless fragment # fragment may be nil if you turn the monkey patch off.
          fragment.insert 0, buffer
          buffer = ""
          
          fragment.each_line do |line|
            buffer = line and next unless line[-1] == ?\n
            if line =~ IMAGE_PATTERN
              url, filename = $1, $2.gsub(/(\..+?)/, " — #$3\\1")
              next if @downloaded_files.include? filename
              yield url, filename
            elsif @first_post_time.nil? and line =~ FIRST_POST_TIME_PATTERN
              @first_post_time = self.class.parse_time $1
            end
          end
        end
      end
    end
  end
  
  def download url, filename
    @downloaded_files << filename
    thread = Thread.new filename, url do
      begin
        log "Downloading #{filename}"
        open "#@directory/#{filename}", "wb" do |file|
          Net::HTTP.start @thread_url.host, 80 do |http|
            http.get URI.parse(url).path do |fragment|
              file.write fragment
            end
          end
        end
        log "Done downloading #{filename}. Remaining downloads: #{thread_count-1}"
      rescue
        log "ERROR DOWNLOADING #{filename}: #{e.inspect}"
      ensure
        remove_thread Thread.current
      end
    end
    add_thread thread
  end
  
  def leech
    log "Downloading all images from #@thread_url."
    log "Target directory is #@directory."
    begin
      loop do
        new_images &method(:download) if has_new?
        sleep 2
      end
    rescue Thread404dError
      log "Thread has 404'd."
      log "Thread lasted %.1f minutes." % ((Time.now - @first_post_time) / 60) if @first_post_time
      thread_count > 0 and begin
        log "Waiting for for downloads to finish; ^C to stop"
        wait_till_done
      rescue Interrupt
        log "Remaining downloads canceled."
      end
      log "Have a nice day!"
    end
  rescue Interrupt
    message, threads = "Aborted!", thread_count
    message << " #{threads} download#{threads>1&&"s"} stopped." if threads > 0
    log message
  end
  
  def log message
    @log_semaphore.synchronize do
      puts Time.now.to_s + ": " + message.to_s
    end
  end
  
  def add_thread thread
    @thread_array_semaphore.synchronize do
      @threads << thread
    end
  end
  
  def remove_thread thread
    @thread_array_semaphore.synchronize do
      @threads.delete thread
    end    
  end
  
  def thread_count
    @thread_array_semaphore.synchronize do
      @threads.length
    end
  end
  
  def wait_till_done
    @thread_array_semaphore.synchronize{ @threads.dup }.each { |t| t.join }
  end
  
  def self.parse_time time_string
    month, day, year, time = time_string.match(%r{(\d\d)/(\d\d)/(\d\d)\(\w+\)(\d\d:\d\d:\d\d)}).captures
    Time.parse("#{year}-#{month}-#{day} #{time} -0500") # Time zone guessed.
  end
end

unless (1..2) === ARGV.length and ARGV[0] =~ /^\d+$/
  $stderr << "Usage: #{File.basename$0} threadnumber [destination=#{DEFAULT_OUTPUT_DIRECTORY%'threadnumber'}]\n"
  exit 1
end

thread_number = ARGV[0].to_i
output_directory = ARGV[1] || File.expand_path(DEFAULT_OUTPUT_DIRECTORY % thread_number)

FileUtils.mkdir_p output_directory
FourChan.leech thread_number, output_directory
