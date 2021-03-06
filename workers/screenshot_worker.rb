require 'rmagick'
require 'timeout'
require 'securerandom'
require 'thread'
require 'open3'

# Don't judge - Ruby handling of timeouts is a joke..
module Phantomjs
  def self.run(*args, &block)
    pid = nil
    stdin, stdout, stderr, wait_thr = nil
    begin
      Timeout::timeout(30) do
        stdin, stdout, stderr, wait_thr = Open3.popen3(path, *args)
        pid = wait_thr.pid
        wait_thr.join
        return stdout.read
      end
    # :nocov:
    rescue Timeout::Error
      stdin.close
      stdout.close
      stderr.close
      Process.kill 'QUIT', pid
      raise Timeout::Error
    end
    # :nocov:
  end
end

class ScreenshotWorker
  SCREENSHOTS_PATH = Site::SCREENSHOTS_ROOT
  include Sidekiq::Worker
  sidekiq_options queue: :screenshots, retry: 3, backtrace: true

  def perform(username, path)
    path = "/#{path}" unless path[0] == '/'
    screenshot = Tempfile.new 'neocities_screenshot'
    screenshot.close
    screenshot_output_path = screenshot.path+'.png'

    begin
      f = Screencap::Fetcher.new("http://#{username}.neocities.org#{path}")
      f.fetch(
        output: screenshot_output_path,
        width: 1280,
        height: 960,
        maxRenderWait: 25000,
        cutoffWait: 30000
      )
    rescue Timeout::Error
      # :nocov:
      puts "#{username}/#{path} is timing out, discontinuing"
      site = Site[username: username]
      site.is_crashing = true
      site.save_changes validate: false

      # Don't enable until we know it works well.
=begin
      if site.email
        EmailWorker.perform_async({
          from: 'web@neocities.org',
          to: site.email,
          subject: "[NeoCities] The web page \"#{path}\" on your site (#{username}.neocities.org) is slow",
          body: "Hi there! This is an automated email to inform you that we're having issues loading your site to take a "+
                "screenshot. It is possible that this is an error specific to our screenshot program, but it is much more "+
                "likely that your site is too slow to be used with browsers. We don't want Neocities sites crashing browsers, "+
                "so we're taking steps to inform you and see if you can resolve the issue. "+
                "We may have to de-list your web site from being viewable in our browse page if it is not resolved shortly. "+
                "We will review the site manually before taking this step, so don't worry if your site is fine and we made "+
                "a mistake."+
                "\n\nOur best,\n- Neocities"
        })
      end
=end
      return
      # :nocov:
    end

    img_list = Magick::ImageList.new
    img_list.from_blob File.read(screenshot_output_path)

    screenshot.unlink
    File.unlink screenshot_output_path

    img_list.new_image(img_list.first.columns, img_list.first.rows) { self.background_color = "white" }
    img = img_list.reverse.flatten_images

    user_screenshots_path = File.join SCREENSHOTS_PATH, username
    screenshot_path = File.join user_screenshots_path, File.dirname(path)

    FileUtils.mkdir_p screenshot_path unless Dir.exists?(screenshot_path)

    Site::SCREENSHOT_RESOLUTIONS.each do |res|
      width, height = res.split('x').collect {|r| r.to_i}

      if width == height
        new_img = img.crop_resized width, height, Magick::NorthGravity
      else
        new_img = img.scale width, height
      end

      new_img.write(File.join(user_screenshots_path, "#{path}.#{res}.jpg")) {
        self.quality = 90
      }
    end
  end
end
