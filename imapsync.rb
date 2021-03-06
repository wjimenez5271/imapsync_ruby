#!/usr/bin/env ruby
require 'net/imap'
require 'trollop'

opts = Trollop::options do
   opt :dynamic_folder_map, "Build folder map based on IMAP search"
   opt :max_retry, "Number of times to retry after IMAP connection timeout"
end

# Source server connection info.
SOURCE_HOST = 'imap.gmail.com'
SOURCE_PORT = 993
SOURCE_SSL  = true
SOURCE_USER = 'uname@domain'
SOURCE_PASS = 'passwd'

# Destination server connection info.
DEST_HOST = 'imap.gmail.com'
DEST_PORT = 993
DEST_SSL  = true
DEST_USER = 'uname@domain'
DEST_PASS = 'passwd'

UID_BLOCK_SIZE = 1024 # max number of messages to select at once

# Mapping of source folders to destination folders. The key is the name of the
# folder on the source server, the value is the name on the destination server.
# Any folder not specified here will be ignored. If a destination folder does
# not exist, it will be created.
FOLDERS = {
  'INBOX' => 'INBOX',
  '[Gmail]/Sent Mail' => '[Gmail]/Sent Mail',
  '[Gmail]/All Mail' => '[Gmail]/All Mail'
}

# Utility methods.
def get_folders(imap_obj)
   # Build a mapping of folders from IMAP folder search
   folders = imap_obj.list('', '*')  # Returns a list of Net::IMAP::MailboxList objects
   folder_map = {}
   folders.each do
      puts "Discovered folder: #{folder.name}"
      folder_map[folder.name] = folder.name
   end
   return folder_map
end

def dd(message)
   puts "[#{DEST_HOST}: #{DEST_USER}] #{message}"
end

def ds(message)
   puts "[#{SOURCE_HOST}: #{SOURCE_USER}] #{message}"
end

def uid_fetch_block(server, uids, *args)
  pos = 0
  while pos < uids.size
    server.uid_fetch(uids[pos, UID_BLOCK_SIZE], *args).each { |data| yield data }
    pos += UID_BLOCK_SIZE
  end
end

def process_mail_queue
  # Connect and log into both servers.
  ds 'connecting...'
  source = Net::IMAP.new(SOURCE_HOST, SOURCE_PORT, SOURCE_SSL)

  ds 'logging in...'
  source.login(SOURCE_USER, SOURCE_PASS)

  dd 'connecting...'
  dest = Net::IMAP.new(DEST_HOST, DEST_PORT, DEST_SSL)

  dd 'logging in...'
  dest.login(DEST_USER, DEST_PASS)

  # build folder map if cmd line option was passed
  if opts[:dynamic_folder_map]
     FOLDERS = get_folders(ds)
  end
  # Loop through folders and copy messages.
  FOLDERS.each do |source_folder, dest_folder|
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
        msg = source.uid_fetch(data.attr['UID'], ['RFC822', 'FLAGS',
            'INTERNALDATE']).first

        # Append the message to the destination folder, preserving flags and
        # internal timestamp.
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

  puts 'done'
end


# actual control flow
retries = 0
max_retry = 5
if opts[:max_retry]
  max_retry = opts[:max_retry]
end

begin
  process_mail_queue
rescue Net::IMAP::ByeResponseError
  retry_count = retries + 1
  if retries < max_retry
    process_mail_queue
  end
end
