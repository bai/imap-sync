#!/usr/bin/env ruby

if $PROGRAM_NAME == __FILE__
  require 'yaml'
  if ARGV
    require 'open-uri'
    begin
      C = YAML.load(open(ARGV[0]))
    rescue
      raise "Unable to fetch configuration file."
    end
  else
    C = YAML.load(File.read('configuration.yml'))
  end
end

require 'net/imap'

def dd(message)
  puts "[#{C['source']['host']}] #{message}"
end

def ds(message)
  puts "[#{C['destination']['host']}] #{message}"
end

# 1024 is the max number of messages to select at once
def uid_fetch_block(server, uids, *args)
  pos = 0
  while pos < uids.size
    server.uid_fetch(uids[pos, 1024], *args).each { |data| yield data }
    pos += 1024
  end
end

def compare_folders(source, dest, source_folder, dest_folder)
  # Open source folder in read-only mode.
  begin
    ds "selecting folder '#{source_folder}'..."
    source.examine(source_folder)
  rescue => e
    ds "error: select failed: #{e}"
    next
  end

  # Open (or create) destination folder in read-write mode.
  begin
    dd "selecting folder '#{dest_folder}'..."
    dest.select(dest_folder)
  rescue => e
    begin
      dd "folder not found; creating..."
      dest.create(dest_folder)
      dest.select(dest_folder)
    rescue => ee
      dd "error: could not create folder: #{e}"
      next
    end
  end

  # Build a lookup hash of all message ids present in the destination folder.
  dest_info = {}

  dd 'analyzing existing messages...'
  uids = dest.uid_search(['ALL'])
  dd "found #{uids.length} messages"
  if uids.length > 0
    uid_fetch_block(dest, uids, ['ENVELOPE']) do |data|
      dest_info[data.attr['ENVELOPE'].message_id] = true
    end
  end

  # Loop through all messages in the source folder.
  uids = source.uid_search(['ALL'])
  ds "found #{uids.length} messages"
  if uids.length > 0
    uid_fetch_block(source, uids, ['ENVELOPE']) do |data|
      mid = data.attr['ENVELOPE'].message_id

      # If this message is already in the destination folder, skip it.
      next if dest_info[mid]

      # Download the full message body from the source folder.
      ds "downloading message #{mid}..."
      msg = source.uid_fetch(data.attr['UID'], ['RFC822', 'FLAGS', 'INTERNALDATE']).first

      # Append the message to the destination folder, preserving flags and internal timestamp.
      dd "storing message #{mid}..."
      success = false
      begin
        dest.append(dest_folder, msg.attr['RFC822'], msg.attr['FLAGS'], msg.attr['INTERNALDATE'])
        success = true
      rescue Net::IMAP::NoResponseError => e
        puts "Got exception: #{e.message}. Retrying..."
        sleep 1
      end until success
    end
  end

  source.close
  dest.close
end



# MAIN

# Connect and log into both servers.
ds 'connecting...'
source = Net::IMAP.new(C['source']['host'], C['source']['port'], C['source']['ssl'])

ds 'logging in...'
source.login(C['source']['username'], C['source']['password'])

dd 'connecting...'
dest = Net::IMAP.new(C['destination']['host'], C['destination']['port'], C['destination']['ssl'])

dd 'logging in...'
dest.login(C['destination']['username'], C['destination']['password'])


# Loop through folders and copy messages.
if C["all_folders"]
  ds "Processing all source folders"

  folders = source.list("", "*")
  folders.each do |f|
    compare_folders(source, dest, f.name, f.name)
  end
else
  ds "Processing source folder list from configuration"

  C['mappings'].each do |source_folder, dest_folder|
    compare_folders(source, dest, source_folder, dest_folder)
  end
end
