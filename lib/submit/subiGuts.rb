###################################################################################################
# Library of routines used to manipulate items in the Subi pairtree, such as editing and approving
# them (automating the creation and propagation of next/ directories).
class SubiGuts

  ###################################################################################################
  def self.isSequestered(ark)
    File.file?(arkToFile(ark, "CONTENT_SEQUESTERED"))
  end

  ###################################################################################################
  def self.approveItem(ark, message, who=nil)

    # Set the state to 'published'
    setItemState(ark, 'published', message, who)

    # If there's old content in the sequester, blow it away.
    if isSequestered(ark)
      sequesterDir = arkToFile(ark, '').sub('/data/','/data_sequester/')
      puts "Removing old sequester dir #{sequesterDir.inspect}."
      checkCall(["#{$subiDir}/lib/espylib/forcechown.py", sequesterDir])
      FileUtils.rmtree(sequesterDir)
    end
    File.exists?(arkToFile(ark, 'CONTENT_SEQUESTERED')) and File.delete(arkToFile(ark, 'CONTENT_SEQUESTERED'))

    # Move item/next/content to item/content
    path = arkToFile(ark, 'next/content/')
    if File.directory? path
      checkCall(['rsync', '-a', '--delete', path, arkToFile(ark, 'content/')])
    end

    # Same with item/next/rip
    path = arkToFile(ark, 'next/rip/')
    if File.directory? path
      checkCall(['rsync', '-a', '--delete', path, arkToFile(ark, 'rip/')])
    end

    # Then the metadata files
    path = arkToFile(ark, 'meta/base.meta.xml', true)
    isNew = !(File.exist? path)
    File.rename(path, path+".old") unless isNew
    FileUtils.copy_file(arkToFile(ark, 'next/meta/base.meta.xml'), path)

    path = arkToFile(ark, 'next/meta/base.feed.xml')
    if File.file? path
      FileUtils.copy_file(path, arkToFile(ark, 'meta/base.feed.xml', true))
    end

    # License directory too
    path = arkToFile(ark, 'next/meta/license/')
    if File.directory? path
      checkCall(['rsync', '-a', '--delete', path, arkToFile(ark, 'meta/license/')])
    end

    # Blow away the 'next' directory now that it's been copied
    FileUtils.rmtree(arkToFile(ark, 'next/'))

    # Update the preview index so this item will have the correct state in there
    checkCall("#{$controlDir}/tools/queuePreview.py #{ark.sub("ark:/", "ark:")}")

    # Log this in a handy place.
    open("#{$subiDir}/publish.log", "a") { |io|
      io.puts "#{DateTime.now.iso8601}: #{ark.inspect}: #{message}"
    }

    # Fire off a signal to the controller that it needs to work on this item
    checkCall(["#{$controlDir}/tools/sendHarvestMessage.py",
               ark.sub("ark:/", "ark:"), isNew ? 'new' : 'changed', message])
  end

  ###################################################################################################
  # Create a 'next' directory for an item, and make it pending there.
  def self.editItem(ark, message, who=nil, pubID=nil)

    # Skip if the item has never been published.
    File.directory?(arkToFile(ark, 'meta')) or return FileUtils.mkdir_p(arkToFile(ark, 'next/'))

    # Copy the existing data to the 'next' directory, since we're revising.
    mainDir = arkToFile(ark, '')
    nextDir = arkToFile(ark, 'next/')
    checkCall(['rsync', '-a', '--ignore-existing',
               '--filter=- *.history.xml',
               '--filter=- *.cookie.xml',
               '--filter=- next',
               '--filter=- CONTENT_SEQUESTERED',
               '--filter=+ *',
               mainDir, nextDir])

    # If sequestered, grab the content out of the sequester as well.
    if isSequestered(ark)
      seqContentDir = "#{mainDir.sub('/data/','/data_sequester/')}content/"
      if File.exists?(seqContentDir)
        checkCall(['rsync', '-a', '--ignore-existing', seqContentDir, "#{nextDir}content/"])
      end
    end

    # Change the state appropriately
    setItemState(ark, 'pending', message, who)
  end

  ###################################################################################################
  def self.setItemState(ark, state, comment, who=nil)
    metaFile = arkToFile(ark, "next/meta/base.meta.xml")
    File.exists?(metaFile) or return
    editXML(metaFile) do |meta|
      return if meta['state'] == state
      meta['state'] = state
      meta['stateDate'] = DateTime.now.iso8601
      meta['dateStamp'] = DateTime.now.iso8601
      history = meta.find! 'history'
      unless who
        prevChg = history.xpath("stateChange[last()][@who]")[0]
        who = prevChg ? prevChg['who'] : 'help@escholarship.org'
      end
      history.build { |xml|
        xml.stateChange(state:state, who:who, date:DateTime.now.iso8601) {
          xml.comment_(comment) if comment
        }
      }
    end
  end

  ###################################################################################################
  def self.guessMimeType(filePath)
    Rack::Mime.mime_type(File.extname(filePath))
  end

  ###################################################################################################
  def self.getHumanSize(filePath)
    size = File::size(filePath)
    return size > 99*1024 ? "%.1fMB" % (size / 1024.0 / 1024.0) : "%.1fkB" % (size / 1024.0)
  end

end