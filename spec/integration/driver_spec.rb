# frozen_string_literal: true

require "spec_helper"
require "image_size"
require "pdf/reader"
require "chunky_png"

module Capybara::Cuprite
  describe Driver do
    include Spec::Support::ExternalBrowser

    around do |example|
      begin
        @session = TestSessions::Cuprite
        @driver = @session.driver
        example.run
      ensure
        @driver.reset!
      end
    end

    def session_url(path)
      server = @session.server
      "http://#{server.host}:#{server.port}#{path}"
    end

    it "supports a custom path" do
      begin
        original_path = CUPRITE_ROOT + "/spec/support/chrome_path"
        File.write(original_path, @driver.browser.process.path)

        file = CUPRITE_ROOT + "/spec/support/custom_chrome_called"
        path = CUPRITE_ROOT + "/spec/support/custom_chrome"

        driver = Driver.new(nil, browser_path: path)
        driver.browser

        # If the correct custom path is called, it will touch the file.
        # We allow at least 10 secs for this to happen before failing.

        tries = 0
        until File.exist?(file) || tries == 100
          sleep 0.1
          tries += 1
        end

        expect(File.exist?(file)).to be true
      ensure
        FileUtils.rm_f(original_path)
        FileUtils.rm_f(file)
        driver&.quit
      end
    end

    context "output redirection" do
      let(:logger) { StringIO.new }
      let(:session) { Capybara::Session.new(:cuprite_with_logger, TestApp) }

      before do
        Capybara.register_driver(:cuprite_with_logger) do |app|
          Capybara::Cuprite::Driver.new(app, logger: logger)
        end
      end

      after { session.driver.quit }

      it "supports capturing console.log" do
        session.visit("/cuprite/console_log")
        expect(logger.string).to include("Hello world")
      end
    end

    it "raises an error and restarts the client if the client dies while executing a command" do
      driver = Capybara::Cuprite::Driver.new(nil)
      expect { driver.browser.crash }.to raise_error(Ferrum::DeadBrowserError)
      driver.visit(session_url("/"))
      expect(driver.html).to include("Hello world")
    end

    it "stops silently before visit call" do
      driver = Capybara::Cuprite::Driver.new(nil)
      expect { driver.quit }.not_to raise_error
    end

    it "has a viewport size of 1024x768 by default" do
      @session.visit("/")
      expect(
        @driver.evaluate_script("[window.innerWidth, window.innerHeight]")
      ).to eq([1024, 768])
    end

    it "allows the viewport to be resized" do
      @session.visit("/")
      @driver.resize(200, 400)
      expect(
        @driver.evaluate_script("[window.innerWidth, window.innerHeight]")
      ).to eq([200, 400])
    end

    it "defaults viewport maximization to 1366x768" do
      @session.visit("/")
      @session.current_window.maximize
      expect(@session.current_window.size).to eq([1366, 768])
    end

    context "custom maximization size" do
      let(:session) { Capybara::Session.new(:cuprite_with_screen_size, TestApp) }

      before do
        Capybara.register_driver(:cuprite_with_screen_size) do |app|
          Capybara::Cuprite::Driver.new(app, screen_size: [1600, 1200])
        end
      end

      after { session.driver.quit }

      it "allows passing screen size" do
        session.visit("/")
        session.current_window.maximize
        expect(session.current_window.size).to eq([1600, 1200])
      end
    end

    it "allows the page to be scrolled" do
      @session.visit("/cuprite/long_page")
      @driver.resize(10, 10)
      @driver.scroll_to(200, 100)
      expect(
        @driver.evaluate_script("[window.scrollX, window.scrollY]")
      ).to eq([200, 100])
    end

    it "supports specifying viewport size with an option" do
      begin
        Capybara.register_driver :cuprite_with_custom_window_size do |app|
          Capybara::Cuprite::Driver.new(app, window_size: [800, 600])
        end
        driver = Capybara::Session.new(:cuprite_with_custom_window_size, TestApp).driver
        driver.visit(session_url("/"))
        expect(
          driver.evaluate_script("[window.innerWidth, window.innerHeight]")
        ).to eq([800, 600])
      ensure
        driver&.quit
      end
    end

    shared_examples "render screen" do
      it "supports rendering the whole of a page that goes outside the viewport" do
        @session.visit("/cuprite/long_page")

        create_screenshot file
        File.open(file, "rb") do |f|
          expect(ImageSize.new(f.read).size).to eq(
            @driver.evaluate_script("[window.innerWidth, window.innerHeight]")
          )
        end

        create_screenshot file, full: true
        File.open(file, "rb") do |f|
          expect(ImageSize.new(f.read).size).to eq(
            @driver.evaluate_script("[document.documentElement.clientWidth, document.documentElement.clientHeight]")
          )
        end
      end

      it "supports rendering the entire window when documentElement has no height" do
        @session.visit("/cuprite/fixed_positioning")

        create_screenshot file, full: true
        File.open(file, "rb") do |f|
          expect(ImageSize.new(f.read).size).to eq(
            @driver.evaluate_script("[window.innerWidth, window.innerHeight]")
          )
        end
      end

      it "supports rendering just the selected element" do
        @session.visit("/cuprite/long_page")

        create_screenshot file, selector: "#penultimate"

        File.open(file, "rb") do |f|
          size = @driver.evaluate_script <<-JS
            function() {
              var ele  = document.getElementById("penultimate");
              var rect = ele.getBoundingClientRect();
              return [rect.width, rect.height];
            }();
          JS
          expect(ImageSize.new(f.read).size).to eq(size)
        end
      end

      it "ignores :selector in #save_screenshot if full: true" do
        @session.visit("/cuprite/long_page")
        expect(@driver.browser.page).to receive(:warn).with(/Ignoring :selector/)

        create_screenshot file, full: true, selector: "#penultimate"

        File.open(file, "rb") do |f|
          expect(ImageSize.new(f.read).size).to eq(
            @driver.evaluate_script("[document.documentElement.clientWidth, document.documentElement.clientHeight]")
          )
        end
      end

      it "resets element positions after" do
        @session.visit("cuprite/long_page")
        el = @session.find(:css, "#middleish")
        # make the page scroll an element into view
        el.click
        position_script = "document.querySelector('#middleish').getBoundingClientRect()"
        offset = @session.evaluate_script(position_script)
        create_screenshot file
        expect(@session.evaluate_script(position_script)).to eq offset
      end
    end

    describe "#save_screenshot" do
      let(:format) { :png }
      let(:file) { "#{CUPRITE_ROOT}/spec/tmp/screenshot.#{format}" }

      after do
        FileUtils.rm_f("#{CUPRITE_ROOT}/spec/tmp/screenshot.pdf")
        FileUtils.rm_f("#{CUPRITE_ROOT}/spec/tmp/screenshot.png")
      end

      def create_screenshot(file, *args)
        @driver.save_screenshot(file, *args)
      end

      it "supports rendering the page" do
        @session.visit("/")

        @driver.save_screenshot(file)

        expect(File.exist?(file)).to be true
      end

      it "supports rendering the page with a nonstring path" do
        @session.visit("/")

        @driver.save_screenshot(Pathname(file))

        expect(File.exist?(file)).to be true
      end

      it "supports rendering the page to file without extension when format is specified" do
        begin
          file = CUPRITE_ROOT + "/spec/tmp/screenshot"
          @session.visit("/")

          @driver.save_screenshot(file, format: "jpg")

          expect(File.exist?(file)).to be true
        ensure
          FileUtils.rm_f(file)
        end
      end

      it "supports rendering the page with different quality settings" do
        file2 = CUPRITE_ROOT + "/spec/tmp/screenshot2.jpeg"
        file3 = CUPRITE_ROOT + "/spec/tmp/screenshot3.jpeg"
        FileUtils.rm_f([file2, file3])

        begin
          @session.visit("/")
          @driver.save_screenshot(file, quality: 0) # ignored for png
          @driver.save_screenshot(file2) # defaults to a quality of 75
          @driver.save_screenshot(file3, quality: 100)
          expect(File.size(file)).to be > File.size(file2) # png by defult is bigger
          expect(File.size(file2)).to be < File.size(file3)
        ensure
          FileUtils.rm_f([file2, file3])
        end
      end

      shared_examples "when #zoom_factor= is set" do
        it "changes image dimensions" do
          @session.visit("/cuprite/zoom_test")

          black_pixels_count = lambda { |file|
            img = ChunkyPNG::Image.from_file(file)
            img.pixels.inject(0) { |i, p| p > 255 ? i + 1 : i }
          }
          @driver.save_screenshot(file)
          before = black_pixels_count[file]

          @driver.zoom_factor = zoom_factor
          @driver.save_screenshot(file)
          after = black_pixels_count[file]

          expect(after.to_f / before.to_f).to eq(zoom_factor**2)
        end
      end

      context "zoom in" do
        let(:zoom_factor) { 2 }
        include_examples "when #zoom_factor= is set"
      end

      context "zoom out" do
        let(:zoom_factor) { 0.5 }
        include_examples "when #zoom_factor= is set"
      end

      context "when #paper_size= is set" do
        let(:format) { :pdf }

        it "changes pdf size" do
          @session.visit("/cuprite/long_page")
          @driver.paper_size = { width: "1in", height: "1in" }

          @driver.save_screenshot(file)

          reader = PDF::Reader.new(file)
          reader.pages.each do |page|
            bbox   = page.attributes[:MediaBox]
            width  = (bbox[2] - bbox[0]) / 72
            expect(width).to eq(1)
          end
        end
      end

      include_examples "render screen"
    end

    describe "#render_base64" do
      let(:file) { "#{CUPRITE_ROOT}/spec/tmp/screenshot.#{format}" }

      def create_screenshot(file, *args)
        image = @driver.render_base64(format, *args)
        File.open(file, "wb") { |f| f.write Base64.decode64(image) }
      end

      it "supports rendering the page in base64" do
        @session.visit("/")

        screenshot = @driver.render_base64

        expect(screenshot.length).to be > 100
      end

      context "png" do
        let(:format) { :png }
        after { FileUtils.rm_f(file) }

        include_examples "render screen"
      end

      context "jpeg" do
        let(:format) { :jpeg }
        after { FileUtils.rm_f(file) }

        include_examples "render screen"
      end
    end

    context "setting headers" do
      it "allows headers to be set" do
        @driver.headers = {
          "Cookie" => "foo=bar",
          "DV" => "hello"
        }
        @session.visit("/cuprite/headers")
        expect(@driver.body).to include("COOKIE: foo=bar")
        expect(@driver.body).to include("DV: hello")
      end

      it "allows headers to be read" do
        expect(@driver.headers).to eq({})
        @driver.headers = { "User-Agent" => "Browser", "Host" => "foo.com" }
        expect(@driver.headers).to eq("User-Agent" => "Browser", "Host" => "foo.com")
      end

      it "supports User-Agent" do
        @driver.headers = { "User-Agent" => "foo" }
        @session.visit "/"
        expect(@driver.evaluate_script("window.navigator.userAgent")).to eq("foo")
      end

      it "sets headers for all HTTP requests" do
        @driver.headers = { "X-Omg" => "wat" }
        @session.visit "/"
        @driver.execute_script <<-JS
          var request = new XMLHttpRequest();
          request.open("GET", "/cuprite/headers", false);
          request.send();

          if (request.status === 200) {
            document.body.innerHTML = request.responseText;
          }
        JS
        expect(@driver.body).to include("X_OMG: wat")
      end

      it "adds new headers" do
        @driver.headers = { "User-Agent" => "Browser", "DV" => "hello" }
        @driver.add_headers("User-Agent" => "Cuprite", "Appended" => "true")
        @session.visit("/cuprite/headers")
        expect(@driver.body).to include("USER_AGENT: Cuprite")
        expect(@driver.body).to include("DV: hello")
        expect(@driver.body).to include("APPENDED: true")
      end

      it "sets headers on the initial request for referer only" do
        @driver.headers = { "PermanentA" => "a" }
        @driver.add_headers("PermanentB" => "b")
        @driver.add_header("Referer", "http://google.com", permanent: false)
        @driver.add_header("TempA", "a", permanent: false) # simply ignored

        @session.visit("/cuprite/headers_with_ajax")
        initial_request = @session.find(:css, "#initial_request").text
        ajax_request = @session.find(:css, "#ajax_request").text

        expect(initial_request).to include("PERMANENTA: a")
        expect(initial_request).to include("PERMANENTB: b")
        expect(initial_request).to include("REFERER: http://google.com")
        expect(initial_request).to include("TEMPA: a")

        expect(ajax_request).to include("PERMANENTA: a")
        expect(ajax_request).to include("PERMANENTB: b")
        expect(ajax_request).to_not include("REFERER: http://google.com")
        expect(ajax_request).to include("TEMPA: a")
      end

      it "keeps added headers on redirects" do
        @driver.add_header("X-Custom-Header", "1", permanent: false)
        @session.visit("/cuprite/redirect_to_headers")
        expect(@driver.body).to include("X_CUSTOM_HEADER: 1")
      end

      context "multiple windows", skip: true do
        it "persists headers across popup windows" do
          @driver.headers = {
            "Cookie" => "foo=bar",
            "Host" => "foo.com",
            "User-Agent" => "foo"
          }
          @session.visit("/cuprite/popup_headers")
          @session.click_link "pop up"
          @session.switch_to_window @session.windows.last
          expect(@driver.body).to include("USER_AGENT: foo")
          expect(@driver.body).to include("COOKIE: foo=bar")
          expect(@driver.body).to include("HOST: foo.com")
        end

        it "sets headers in existing windows" do
          @session.open_new_window
          @driver.headers = {
            "Cookie" => "foo=bar",
            "Host" => "foo.com",
            "User-Agent" => "foo"
          }
          @session.visit("/cuprite/headers")
          expect(@driver.body).to include("USER_AGENT: foo")
          expect(@driver.body).to include("COOKIE: foo=bar")
          expect(@driver.body).to include("HOST: foo.com")

          @session.switch_to_window @session.windows.last
          @session.visit("/cuprite/headers")
          expect(@driver.body).to include("USER_AGENT: foo")
          expect(@driver.body).to include("COOKIE: foo=bar")
          expect(@driver.body).to include("HOST: foo.com")
        end

        it "keeps temporary headers local to the current window" do
          @session.open_new_window
          @driver.add_header("X-Custom-Header", "1", permanent: false)

          @session.switch_to_window @session.windows.last
          @session.visit("/cuprite/headers")
          expect(@driver.body).not_to include("X_CUSTOM_HEADER: 1")

          @session.switch_to_window @session.windows.first
          @session.visit("/cuprite/headers")
          expect(@driver.body).to include("X_CUSTOM_HEADER: 1")
        end

        it "does not mix temporary headers with permanent ones when propagating to other windows" do
          @session.open_new_window
          @driver.add_header("X-Custom-Header", "1", permanent: false)
          @driver.add_header("Host", "foo.com")

          @session.switch_to_window @session.windows.last
          @session.visit("/cuprite/headers")
          expect(@driver.body).to include("HOST: foo.com")
          expect(@driver.body).not_to include("X_CUSTOM_HEADER: 1")

          @session.switch_to_window @session.windows.first
          @session.visit("/cuprite/headers")
          expect(@driver.body).to include("HOST: foo.com")
          expect(@driver.body).to include("X_CUSTOM_HEADER: 1")
        end

        it "does not propagate temporary headers to new windows" do
          @session.visit "/"
          @driver.add_header("X-Custom-Header", "1", permanent: false)
          @session.open_new_window

          @session.switch_to_window @session.windows.last
          @session.visit("/cuprite/headers")
          expect(@driver.body).not_to include("X_CUSTOM_HEADER: 1")

          @session.switch_to_window @session.windows.first
          @session.visit("/cuprite/headers")
          expect(@driver.body).to include("X_CUSTOM_HEADER: 1")
        end
      end
    end

    it "supports clicking precise coordinates" do
      @session.visit("/cuprite/click_coordinates")
      @driver.click(100, 150)
      expect(@driver.body).to include("x: 100, y: 150")
    end

    it "supports executing multiple lines of javascript" do
      @driver.execute_script <<-JS
        var a = 1
        var b = 2
        window.result = a + b
      JS
      expect(@driver.evaluate_script("window.result")).to eq(3)
    end

    it "supports stopping the session", skip: Ferrum.windows? do
      driver = Capybara::Cuprite::Driver.new(nil)
      pid = driver.browser.process.pid

      expect(Process.kill(0, pid)).to eq(1)
      driver.quit

      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    end

    context "extending browser javascript" do
      it "supports extending the browser's world" do
        begin
          extended_driver = Capybara::Cuprite::Driver.new(
            @session.app,
            extensions: [File.expand_path("../support/geolocation.js", __dir__)]
          )

          extended_driver.visit session_url("/cuprite/requiring_custom_extension")

          expect(
            extended_driver.body
          ).to include(%(Location: <span id="location">1,-1</span>))

          expect(
            extended_driver.evaluate_script(%(document.getElementById("location").innerHTML))
          ).to eq("1,-1")

          expect(
            extended_driver.evaluate_script("navigator.geolocation")
          ).to_not eq(nil)
        ensure
          extended_driver.quit
        end
      end

      it "errors when extension is unavailable" do
        begin
          failing_driver = Capybara::Cuprite::Driver.new(
            @session.app,
            extensions: [File.expand_path("../support/non_existent.js", __dir__)]
          )
          expect { failing_driver.visit(session_url("/")) }.to raise_error(Errno::ENOENT)
        ensure
          failing_driver.quit
        end
      end
    end

    context "javascript errors" do
      let(:driver) { Capybara::Cuprite::Driver.new(@session.app, js_errors: true) }

      it "propagates a Javascript error inside Cuprite to a ruby exception" do
        expect do
          driver.browser.browser_error
        end.to raise_error(Ferrum::JavaScriptError) { |e|
          expect(e.message).to include("Error: zomg")
          expect(e.message).to include("Cuprite.browserError")
        }
      end

      it "propagates an asynchronous Javascript error on the page to a ruby exception" do
        expect do
          driver.execute_script "setTimeout(function() { omg }, 0)"
          sleep 0.01
          driver.execute_script ""
        end.to raise_error(Ferrum::JavaScriptError, /ReferenceError.*omg/)
      end

      it "propagates a synchronous Javascript error on the page to a ruby exception" do
        expect do
          driver.execute_script "omg"
        end.to raise_error(Ferrum::JavaScriptError, /ReferenceError.*omg/)
      end

      it "does not re-raise a Javascript error if it is rescued" do
        expect do
          driver.execute_script "setTimeout(function() { omg }, 0)"
          sleep 0.01
          driver.execute_script ""
        end.to raise_error(Ferrum::JavaScriptError)

        # should not raise again
        expect(driver.evaluate_script("1+1")).to eq(2)
      end

      it "propagates a Javascript error during page load to a ruby exception" do
        expect { driver.visit session_url("/cuprite/js_error") }.to raise_error(Ferrum::JavaScriptError)
      end

      it "does not propagate a Javascript error to ruby if error raising disabled" do
        begin
          driver = Capybara::Cuprite::Driver.new(@session.app, js_errors: false)
          driver.visit session_url("/cuprite/js_error")
          driver.execute_script "setTimeout(function() { omg }, 0)"
          sleep 0.1
          expect(driver.body).to include("hello")
        ensure
          driver&.quit
        end
      end

      it "does not propagate a Javascript error to ruby if error raising disabled and client restarted" do
        begin
          driver = Capybara::Cuprite::Driver.new(@session.app, js_errors: false)
          driver.restart
          driver.visit session_url("/cuprite/js_error")
          driver.execute_script "setTimeout(function() { omg }, 0)"
          sleep 0.1
          expect(driver.body).to include("hello")
        ensure
          driver&.quit
        end
      end
    end

    context "browser failed responses" do
      before { @port = @session.server.port }

      it "do not occur when DNS correct" do
        expect { @session.visit("http://localhost:#{@port}/") }.not_to raise_error
      end

      it "handles when DNS incorrect" do
        expect { @session.visit("http://nope:#{@port}/") }.to raise_error(Ferrum::StatusError)
      end

      it "has a descriptive message when DNS incorrect" do
        url = "http://nope:#{@port}/"
        expect { @session.visit(url) }
          .to raise_error(
            Ferrum::StatusError,
            %(Request to #{url} failed to reach server, check DNS and server status)
          )
      end

      it "operates a timeout when communicating with browser" do
        begin
          old_timeout = @driver.timeout
          @driver.timeout = 0.1
          expect {
            @driver.visit(session_url("/cuprite/really_slow"))
          }.to raise_error(
            Ferrum::StatusError,
            %r{there are still pending connections: http://.*/cuprite/really_slow}
          )
        ensure
          @driver.timeout = old_timeout
        end
      end

      it "reports open resource requests" do
        begin
          old_timeout = @session.driver.timeout
          @session.driver.timeout = 2
          expect {
            @session.visit("/cuprite/visit_timeout")
          }.to raise_error(
            Ferrum::StatusError,
            %r{there are still pending connections: http://.*/cuprite/really_slow}
          )
        ensure
          @session.driver.timeout = old_timeout
        end
      end

      it "does not report open resources where there are none" do
        old_timeout = @session.driver.timeout
        begin
          @session.driver.timeout = 4
          expect { @session.visit("/cuprite/really_slow") }.not_to raise_error
        ensure
          @session.driver.timeout = old_timeout
        end
      end
    end

    context "network traffic" do
      it "keeps track of network traffic" do
        @session.visit("/cuprite/with_js")
        urls = @driver.network_traffic.map { |e| e.request.url }

        expect(urls.grep(%r{/cuprite/jquery.min.js$}).size).to eq(1)
        expect(urls.grep(%r{/cuprite/jquery-ui.min.js$}).size).to eq(1)
        expect(urls.grep(%r{/cuprite/test.js$}).size).to eq(1)
      end

      it "keeps track of blocked network traffic" do
        @driver.browser.url_blacklist = ["unwanted"]

        @session.visit "/cuprite/url_blacklist"

        blocked_urls = @driver.network_traffic(:blocked).map { |e| e.request.url }

        expect(blocked_urls).to include(/unwanted/)
      end

      it "captures responses" do
        @session.visit("/cuprite/with_js")
        request = @driver.network_traffic.last

        expect(request.response.status).to eq(200)
      end

      it "captures errors" do
        @session.visit("/cuprite/with_ajax_fail")
        expect(@session).to have_css("h1", text: "Done")
        error = @driver.network_traffic.last.error

        expect(error).to be
      end

      it "keeps a running list between multiple web page views" do
        @session.visit("/cuprite/with_js")
        expect(@driver.network_traffic.length).to eq(4)

        @session.visit("/cuprite/with_js")
        expect(@driver.network_traffic.length).to eq(8)
      end

      it "gets cleared on restart" do
        @session.visit("/cuprite/with_js")
        expect(@driver.network_traffic.length).to eq(4)

        @driver.restart

        @session.visit("/cuprite/with_js")
        expect(@driver.network_traffic.length).to eq(4)
      end

      it "gets cleared when being cleared" do
        @session.visit("/cuprite/with_js")
        expect(@driver.network_traffic.length).to eq(4)

        @driver.clear_network_traffic

        expect(@driver.network_traffic.length).to eq(0)
      end

      it "blocked requests get cleared along with network traffic" do
        @driver.browser.url_blacklist = ["unwanted"]

        @session.visit "/cuprite/url_blacklist"

        expect(@driver.network_traffic(:blocked).length).to eq(3)

        @driver.clear_network_traffic

        expect(@driver.network_traffic(:blocked).length).to eq(0)
      end

      it "counts network traffic for each loaded resource" do
        @session.visit("/cuprite/with_js")
        responses = @driver.network_traffic.map(&:response)
        resources_size = {
          %r{/cuprite/jquery.min.js$}    => File.size(CUPRITE_ROOT + "/spec/support/public/jquery-1.11.3.min.js"),
          %r{/cuprite/jquery-ui.min.js$} => File.size(CUPRITE_ROOT + "/spec/support/public/jquery-ui-1.11.4.min.js"),
          %r{/cuprite/test.js$}          => File.size(CUPRITE_ROOT + "/spec/support/public/test.js"),
          %r{/cuprite/with_js$}          => 2405
        }

        resources_size.each do |resource, size|
          expect(responses.find { |r| r.url[resource] }.body_size).to eq(size)
        end
      end
    end

    it "can clear memory cache" do
      @driver.clear_memory_cache

      @session.visit("/cuprite/cacheable")
      first_request = @driver.network_traffic.last
      expect(@driver.network_traffic.length).to eq(1)
      expect(first_request.response.status).to eq(200)

      @session.refresh
      expect(@driver.network_traffic.length).to eq(2)
      expect(@driver.network_traffic.last.response.status).to eq(304)

      @driver.clear_memory_cache

      @session.refresh
      another_request = @driver.network_traffic.last
      expect(@driver.network_traffic.length).to eq(3)
      expect(another_request.response.status).to eq(200)
    end

    context "status code support" do
      it "determines status from the simple response" do
        @session.visit("/cuprite/status/500")
        expect(@driver.status_code).to eq(500)
      end

      it "determines status code when the page has a few resources" do
        @session.visit("/cuprite/with_different_resources")
        expect(@driver.status_code).to eq(200)
      end

      it "determines status code even after redirect" do
        @session.visit("/cuprite/redirect")
        expect(@driver.status_code).to eq(200)
      end
    end

    context "cookies support" do
      it "returns set cookies" do
        @session.visit("/set_cookie")

        cookie = @driver.cookies["capybara"]
        expect(cookie.name).to eq("capybara")
        expect(cookie.value).to eq("test_cookie")
        expect(cookie.domain).to eq("127.0.0.1")
        expect(cookie.path).to eq("/")
        expect(cookie.size).to eq(19)
        expect(cookie.secure?).to be false
        expect(cookie.httponly?).to be false
        expect(cookie.session?).to be true
        expect(cookie.expires).to be_nil
      end

      it "can set cookies" do
        @driver.set_cookie "capybara", "omg"
        @session.visit("/get_cookie")
        expect(@driver.body).to include("omg")
      end

      it "can set cookies with custom settings" do
        @driver.set_cookie "capybara", "omg", path: "/cuprite"

        @session.visit("/get_cookie")
        expect(@driver.body).to_not include("omg")

        @session.visit("/cuprite/get_cookie")
        expect(@driver.body).to include("omg")

        expect(@driver.cookies["capybara"].path).to eq("/cuprite")
      end

      it "can remove a cookie" do
        @session.visit("/set_cookie")

        @session.visit("/get_cookie")
        expect(@driver.body).to include("test_cookie")

        @driver.remove_cookie "capybara"

        @session.visit("/get_cookie")
        expect(@driver.body).to_not include("test_cookie")
      end

      it "can clear cookies" do
        @session.visit("/set_cookie")

        @session.visit("/get_cookie")
        expect(@driver.body).to include("test_cookie")

        @driver.clear_cookies

        @session.visit("/get_cookie")
        expect(@driver.body).to_not include("test_cookie")
      end

      it "can set cookies with an expires time" do
        time = Time.at(Time.now.to_i + 10000)
        @session.visit "/"
        @driver.set_cookie "foo", "bar", expires: time
        expect(@driver.cookies["foo"].expires).to eq(time)
      end

      it "can set cookies for given domain" do
        port = @session.server.port
        @driver.set_cookie "capybara", "127.0.0.1"
        @driver.set_cookie "capybara", "localhost", domain: "localhost"

        @session.visit("http://localhost:#{port}/cuprite/get_cookie")
        expect(@driver.body).to include("localhost")

        @session.visit("http://127.0.0.1:#{port}/cuprite/get_cookie")
        expect(@driver.body).to include("127.0.0.1")
      end

      it "sets cookies correctly when Capybara.app_host is set" do
        old_app_host = Capybara.app_host
        begin
          Capybara.app_host = "http://localhost/cuprite"
          @driver.set_cookie "capybara", "app_host"

          port = @session.server.port
          @session.visit("http://localhost:#{port}/cuprite/get_cookie")
          expect(@driver.body).to include("app_host")

          @session.visit("http://127.0.0.1:#{port}/cuprite/get_cookie")
          expect(@driver.body).not_to include("app_host")
        ensure
          Capybara.app_host = old_app_host
        end
      end
    end

    it "allows the driver to have a fixed port" do
      begin
        driver = Capybara::Cuprite::Driver.new(@driver.app, port: 12345)
        driver.visit session_url("/")

        expect { TCPServer.new("127.0.0.1", 12345) }.to raise_error(Errno::EADDRINUSE)
      ensure
        driver.quit
      end
    end

    it "allows the driver to run tests on external process" do
      with_external_browser do |url|
        begin
          driver = Capybara::Cuprite::Driver.new(@driver.app, url: url)
          driver.visit session_url("/")
          expect(driver.html).to include("Hello world!")
        ensure
          driver&.quit
        end
      end
    end

    it "allows the driver to have a custom host" do
      begin
        # Use custom host "pointing" to localhost, specified by BROWSER_TEST_HOST env var.
        # Use /etc/hosts or iptables for this: https://superuser.com/questions/516208/how-to-change-ip-address-to-point-to-localhost
        host = ENV["BROWSER_TEST_HOST"]

        skip "BROWSER_TEST_HOST not set" if host.nil? # skip test if var is unspecified

        driver = Capybara::Cuprite::Driver.new(@driver.app, host: host, port: 12345)
        driver.visit session_url("/")

        expect { TCPServer.new(host, 12345) }.to raise_error(Errno::EADDRINUSE)
      ensure
        driver&.quit
      end
    end

    it "lists the open windows" do
      @session.visit "/"

      @session.execute_script <<-JS
        window.open("/cuprite/simple", "popup")
      JS

      sleep 0.1

      expect(@driver.window_handles.size).to eq(2)

      popup2 = @session.window_opened_by do
        @session.execute_script <<-JS
          window.open("/cuprite/simple", "popup2")
        JS
      end

      expect(@driver.window_handles.size).to eq(3)

      @session.within_window(popup2) do
        expect(@session.html).to include("Test")
        # Browser isn't dead, current page after executing JS closes connection
        # and we don't have a chance to push response to the Queue. Since the
        # queue and websocket are closed and response is nil the proper guess
        # would be that browser is dead, but in fact the page is dead and
        # browser is fully alive.
        @session.execute_script("window.close()") rescue Ferrum::DeadBrowserError
      end

      sleep 0.1

      expect(@driver.window_handles.size).to eq(2)
    end

    context "a new window inherits settings" do
      it "inherits size" do
        @session.visit "/"
        @session.current_window.resize_to(1200, 800)
        new_tab = @session.open_new_window
        expect(new_tab.size).to eq [1200, 800]
      end

      it "inherits url_blacklist" do
        @driver.browser.url_blacklist = ["unwanted"]
        @session.visit "/"
        new_tab = @session.open_new_window
        @session.within_window(new_tab) do
          @session.visit "/cuprite/url_blacklist"
          expect(@session).to have_content("We are loading some unwanted action here")
          @session.within_frame "framename" do
            expect(@session.html).not_to include("We shouldn't see this.")
          end
        end
      end

      it "inherits url_whitelist" do
        @session.visit "/"
        @driver.browser.url_whitelist = ["url_whitelist", "/cuprite/wanted"]
        new_tab = @session.open_new_window
        @session.within_window(new_tab) do
          @session.visit "/cuprite/url_whitelist"

          expect(@session).to have_content("We are loading some wanted action here")
          @session.within_frame "framename" do
            expect(@session).to have_content("We should see this.")
          end
          @session.within_frame "unwantedframe" do
            # make sure non whitelisted urls are blocked
            expect(@session).not_to have_content("We shouldn't see this.")
          end
        end
      end
    end

    it "resizes windows" do
      @session.visit "/"

      popup1 = @session.window_opened_by do
        @session.execute_script <<-JS
          window.open("/cuprite/simple", "popup1")
        JS
      end

      popup2 = @session.window_opened_by do
        @session.execute_script <<-JS
          window.open("/cuprite/simple", "popup2")
        JS
      end

      popup1.resize_to(100, 200)
      popup2.resize_to(200, 100)

      expect(popup1.size).to eq([100, 200])
      expect(popup2.size).to eq([200, 100])
    end

    it "clears local storage between tests" do
      @session.visit "/"
      @session.execute_script <<-JS
        localStorage.setItem("key", "value");
      JS
      value = @session.evaluate_script <<-JS
        localStorage.getItem("key");
      JS

      expect(value).to eq("value")

      @driver.reset!

      @session.visit "/"
      value = @session.evaluate_script <<-JS
        localStorage.getItem("key");
      JS
      expect(value).to be_nil
    end

    context "basic http authentication" do
      it "denies without credentials" do
        @session.visit "/cuprite/basic_auth"

        expect(@session.status_code).to eq(401)
        expect(@session).not_to have_content("Welcome, authenticated client")
      end

      it "allows with given credentials" do
        @driver.basic_authorize("login", "pass")

        @session.visit "/cuprite/basic_auth"

        expect(@session.status_code).to eq(200)
        expect(@session).to have_content("Welcome, authenticated client")
      end

      it "allows even overwriting headers" do
        @driver.basic_authorize("login", "pass")
        @driver.headers = { "Cuprite" => "true" }

        @session.visit "/cuprite/basic_auth"

        expect(@session.status_code).to eq(200)
        expect(@session).to have_content("Welcome, authenticated client")
      end

      it "denies with wrong credentials" do
        @driver.basic_authorize("user", "pass!")

        @session.visit "/cuprite/basic_auth"

        expect(@session.status_code).to eq(401)
        expect(@session).not_to have_content("Welcome, authenticated client")
      end

      it "allows on POST request" do
        @driver.basic_authorize("login", "pass")

        @session.visit "/cuprite/basic_auth"
        @session.click_button("Submit")

        expect(@session.status_code).to eq(200)
        expect(@session).to have_content("Authorized POST request")
      end
    end

    context "blacklisting urls for resource requests" do
      it "blocks unwanted urls" do
        @driver.browser.url_blacklist = ["unwanted"]

        @session.visit "/cuprite/url_blacklist"

        expect(@session.status_code).to eq(200)
        expect(@session).to have_content("We are loading some unwanted action here")
        @session.within_frame "framename" do
          expect(@session.html).not_to include("We shouldn't see this.")
        end
      end

      it "continues to other intercepted request callbacks if URL is not blacklisted" do
        @driver.browser.url_blacklist = ["unwanted"]

        @driver.browser.on(:request) do |request, index, total|
          if request.match?(/simple/)
            request.respond(body: 'Intercepted')
          else
            request.continue
          end
        end

        @session.visit "/cuprite/simple"

        expect(@session.status_code).to eq(200)
        expect(@session).to have_content("Intercepted")
      end

      it "supports wildcards" do
        @driver.browser.url_blacklist = ["*wanted"]

        @session.visit "/cuprite/url_whitelist"

        expect(@session.status_code).to eq(200)
        expect(@session).to have_content("We are loading some wanted action here")
        @session.within_frame "framename" do
          expect(@session).not_to have_content("We should see this.")
        end
        @session.within_frame "unwantedframe" do
          expect(@session).not_to have_content("We shouldn't see this.")
        end
      end

      it "can be configured in the driver and survive reset" do
        Capybara.register_driver :cuprite_blacklist do |app|
          Capybara::Cuprite::Driver.new(app, @driver.options.merge(url_blacklist: ["unwanted"]))
        end

        session = Capybara::Session.new(:cuprite_blacklist, @session.app)

        session.visit "/cuprite/url_blacklist"
        expect(session).to have_content("We are loading some unwanted action here")
        session.within_frame "framename" do
          expect(session.html).not_to include("We shouldn't see this.")
        end

        session.reset!

        session.visit "/cuprite/url_blacklist"
        expect(session).to have_content("We are loading some unwanted action here")
        session.within_frame "framename" do
          expect(session.html).not_to include("We shouldn't see this.")
        end
      end
    end

    context "whitelisting urls for resource requests" do
      it "allows whitelisted urls" do
        @driver.browser.url_whitelist = ["url_whitelist", "/wanted"]

        @session.visit "/cuprite/url_whitelist"

        expect(@session.status_code).to eq(200)
        expect(@session).to have_content("We are loading some wanted action here")
        @session.within_frame "framename" do
          expect(@session).to have_content("We should see this.")
        end
        @session.within_frame "unwantedframe" do
          expect(@session).not_to have_content("We shouldn't see this.")
        end
      end

      it "continues to other intercepted request callbacks if URL matches whitelist" do
        @driver.browser.url_whitelist = ["url_whitelist", "/wanted"]

        @driver.browser.on(:request) do |request, index, total|
          if request.match?(/wanted/)
            request.respond(body: 'Intercepted')
          else
            request.continue
          end
        end

        @session.visit "/cuprite/url_whitelist"

        expect(@session.status_code).to eq(200)
        expect(@session).to have_content("We are loading some wanted action here")
        @session.within_frame "framename" do
          expect(@session).to have_content("Intercepted")
        end
        @session.within_frame "unwantedframe" do
          expect(@session).not_to have_content("We shouldn't see this.")
        end
      end

      it "supports wildcards" do
        @driver.browser.url_whitelist = ["url_whitelist", "/*wanted"]

        @session.visit "/cuprite/url_whitelist"

        expect(@session.status_code).to eq(200)
        expect(@session).to have_content("We are loading some wanted action here")
        @session.within_frame "framename" do
          expect(@session).to have_content("We should see this.")
        end
        @session.within_frame "unwantedframe" do
          expect(@session).to have_content("We shouldn't see this.")
        end
      end

      it "blocks overruled urls" do
        @driver.browser.url_whitelist = ["url_whitelist"]
        @driver.browser.url_blacklist = ["url_whitelist"]

        @session.visit "/cuprite/url_whitelist"

        expect(@session.status_code).to eq(nil)
        expect(@session).not_to have_content("We are loading some wanted action here")
      end

      it "allows urls when the whitelist is empty" do
        @driver.browser.url_whitelist = []

        @session.visit "/cuprite/url_whitelist"

        expect(@session.status_code).to eq(200)
        expect(@session).to have_content("We are loading some wanted action here")
        @session.within_frame "framename" do
          expect(@session).to have_content("We should see this.")
        end
      end

      it "can be configured in the driver and survive reset" do
        Capybara.register_driver :cuprite_whitelist do |app|
          Capybara::Cuprite::Driver.new(app, @driver.options.merge(url_whitelist: ["url_whitelist", "/cuprite/wanted"]))
        end

        session = Capybara::Session.new(:cuprite_whitelist, @session.app)

        session.visit "/cuprite/url_whitelist"
        expect(session).to have_content("We are loading some wanted action here")
        session.within_frame "framename" do
          expect(session).to have_content("We should see this.")
        end

        session.within_frame "unwantedframe" do
          # make sure non whitelisted urls are blocked
          expect(session).not_to have_content("We shouldn't see this.")
        end

        session.reset!

        session.visit "/cuprite/url_whitelist"
        expect(session).to have_content("We are loading some wanted action here")
        session.within_frame "framename" do
          expect(session).to have_content("We should see this.")
        end
        session.within_frame "unwantedframe" do
          # make sure non whitelisted urls are blocked
          expect(session).not_to have_content("We shouldn't see this.")
        end
      end
    end

    context "combining resource requests blacklist and whitelist" do
      it "permits requests that do not match blacklist and match whitelist" do
        @driver.browser.url_blacklist = ["unwanted"]
        @driver.browser.url_whitelist = ["url_whitelist", "unwanted"]

        @session.visit "/cuprite/url_whitelist"

        expect(@session.status_code).to eq(200)
        expect(@session).to have_content("We are loading some wanted action here")
        @session.within_frame "framename" do
          expect(@session).to_not have_content("We should see this.")
        end
        @session.within_frame "unwantedframe" do
          expect(@session).not_to have_content("We shouldn't see this.")
        end
      end
    end

    context "has ability to send keys" do
      before { @session.visit("/cuprite/send_keys") }

      it "sends keys to empty input" do
        input = @session.find(:css, "#empty_input")

        input.native.send_keys("Input")

        expect(input.value).to eq("Input")
      end

      it "sends keys to filled input" do
        input = @session.find(:css, "#filled_input")

        input.native.send_keys(" appended")

        expect(input.value).to eq("Text appended")
      end

      it "sends keys to empty textarea" do
        input = @session.find(:css, "#empty_textarea")

        input.native.send_keys("Input")

        expect(input.value).to eq("Input")
      end

      it "sends keys to filled textarea" do
        input = @session.find(:css, "#filled_textarea")

        input.native.send_keys(" appended")

        expect(input.value).to eq("Description appended")
      end

      it "sends keys to empty contenteditable div" do
        input = @session.find(:css, "#empty_div")

        input.native.send_keys("Input")

        expect(input.text).to eq("Input")
      end

      it "persists focus across calls" do
        input = @session.find(:css, "#empty_div")

        input.native.send_keys("helo")
        input.native.send_keys(:Left)
        input.native.send_keys("l")

        expect(input.text).to eq("hello")
      end

      it "sends keys to filled contenteditable div" do
        input = @session.find(:css, "#filled_div")

        input.native.send_keys(" appended")

        expect(input.text).to eq("Content appended")
      end

      it "sends sequences" do
        input = @session.find(:css, "#empty_input")

        input.native.send_keys([:Shift], "S", [:Alt], "t", "r", "i", "g", :Left, "n")

        expect(input.value).to eq("String")
      end

      it "submits the form with sequence" do
        input = @session.find(:css, "#without_submit_button input")

        input.native.send_keys(:Enter)

        expect(input.value).to eq("Submitted")
      end

      it "sends sequences with modifiers and letters" do
        input = @session.find(:css, "#empty_input")

        input.native.send_keys([:Shift, "s"], "t", "r", "i", "n", "g")

        expect(input.value).to eq("String")
      end

      it "sends sequences with modifiers and symbols" do
        input = @session.find(:css, "#empty_input")

        keys = Ferrum.mac? ? %i[Alt Left] : %i[Ctrl Left]

        input.native.send_keys("t", "r", "i", "n", "g", keys, "s")

        expect(input.value).to eq("string")
      end

      it "sends sequences with multiple modifiers and symbols" do
        input = @session.find(:css, "#empty_input")

        keys = Ferrum.mac? ? %i[Alt Shift Left] : %i[Ctrl Shift Left]

        input.native.send_keys("t", "r", "i", "n", "g", keys, "s")

        expect(input.value).to eq("s")
      end

      it "sends modifiers with sequences" do
        input = @session.find(:css, "#empty_input")

        input.native.send_keys("s", [:Shift, "tring"])

        expect(input.value).to eq("sTRING")
      end

      it "sends modifiers with multiple keys" do
        input = @session.find(:css, "#empty_input")

        input.native.send_keys("curp", %i[Shift Left Left], "prite")

        expect(input.value).to eq("cuprite")
      end

      it "has an alias" do
        input = @session.find(:css, "#empty_input")

        input.native.send_key("S")

        expect(input.value).to eq("S")
      end

      it "generates correct events with keyCodes for modified puncation" do
        input = @session.find(:css, "#empty_input")

        input.send_keys([:shift, "."], [:shift, "t"])

        expect(@session.find(:css, "#key-events-output")).to have_text("keydown:16 keydown:190 keydown:16 keydown:84")
      end

      it "suuports snake_case sepcified keys (Capybara standard)" do
        input = @session.find(:css, "#empty_input")
        input.send_keys(:PageUp, :page_up)
        expect(@session.find(:css, "#key-events-output")).to have_text("keydown:33", count: 2)
      end

      it "supports :control alias for :Ctrl" do
        input = @session.find(:css, "#empty_input")
        input.send_keys([:Ctrl, "a"], [:control, "a"])
        expect(@session.find(:css, "#key-events-output")).to have_text("keydown:17 keydown:65", count: 2)
      end

      it "supports :command alias for :Meta" do
        input = @session.find(:css, "#empty_input")
        input.send_keys([:Meta, "z"], [:command, "z"])
        expect(@session.find(:css, "#key-events-output")).to have_text("keydown:91 keydown:90", count: 2)
      end

      it "supports Capybara specified numpad keys" do
        input = @session.find(:css, "#empty_input")
        input.send_keys(:numpad2, :numpad8, :divide, :decimal)
        expect(@session.find(:css, "#key-events-output")).to have_text("keydown:98 keydown:104 keydown:111 keydown:110")
      end

      it "raises error for unknown keys" do
        input = @session.find(:css, "#empty_input")
        expect do
          input.send_keys("abc", :blah)
        end.to raise_error KeyError, "key not found: :blah"
      end
    end

    context "set" do
      before { @session.visit("/cuprite/set") }

      it "sets a contenteditable's content" do
        input = @session.find(:css, "#filled_div")
        input.set("new text")
        expect(input.text).to eq("new text")
      end

      it "sets multiple contenteditables' content" do
        input = @session.find(:css, "#empty_div")
        input.set("new text")

        expect(input.text).to eq("new text")

        input = @session.find(:css, "#filled_div")
        input.set("replacement text")

        expect(input.text).to eq("replacement text")
      end

      it "sets a content editable childs content" do
        @session.visit("/with_js")
        @session.find(:css, "#existing_content_editable_child").set("WYSIWYG")
        expect(@session.find(:css, "#existing_content_editable_child").text).to eq("WYSIWYG")
      end

      describe "events" do
        let(:input) { @session.find(:css, "#input") }
        let(:output) { @session.find(:css, "#output") }

        before { @session.visit("/cuprite/input_events") }

        it "calls event handlers in the correct order" do
          input.set("a")
          expect(output.text).to eq("keydown keypress input keyup change")
          expect(input.value).to eq("a")
        end

        it "respects preventDefault() calls in keydown handlers" do
          @session.execute_script "input.addEventListener('keydown', e => e.preventDefault())"
          input.set("a")
          expect(output.text).to eq("keydown keyup")
          expect(input.value).to be_empty
        end

        it "respects preventDefault() calls in keypress handlers" do
          @session.execute_script "input.addEventListener('keypress', e => e.preventDefault())"
          input.set("a")
          expect(output.text).to eq("keydown keypress keyup")
          expect(input.value).to be_empty
        end

        it "calls event handlers for each character input" do
          input.set("abc")
          expect(output.text).to eq((["keydown keypress input keyup"] * 3).join(" ") + " change")
          expect(input.value).to eq("abc")
        end

        it "doesn't call the change event if there is no change" do
          input.set("a")
          input.set("a")
          expect(output.text).to eq("keydown keypress input keyup change keydown keypress input keyup")
        end
      end
    end

    context "date_fields" do
      before { @session.visit("/cuprite/date_fields") }

      it "sets a date" do
        input = @session.find(:css, "#date_field")

        input.set("2016-02-14")

        expect(input.value).to eq("2016-02-14")
      end

      it "fills a date" do
        @session.fill_in "date_field", with: "2016-02-14"

        expect(@session.find(:css, "#date_field").value).to eq("2016-02-14")
      end
    end

    context "evaluate_script" do
      it "can return an element" do
        @session.visit("/cuprite/send_keys")
        element = @session.driver.evaluate_script(%(document.getElementById("empty_input")))
        expect(element).to eq(@session.find(:id, "empty_input"))
      end

      it "can return structures with elements" do
        @session.visit("/cuprite/send_keys")
        result = @session.driver.evaluate_script(%({ a: document.getElementById("empty_input"), b: { c: document.querySelectorAll("#empty_textarea, #filled_textarea") } }))

        expect(result).to eq(
          "a" => @session.driver.find_css("#empty_input").first,
          "b" => {
            "c" => @session.driver.find_css("#empty_textarea, #filled_textarea")
          }
        )
      end
    end

    context "evaluate_async_script" do
      it "handles evaluate_async_script value properly" do
        @session.using_wait_time(5) do
          expect(@session.driver.evaluate_async_script("arguments[0](null)")).to be_nil
          expect(@session.driver.evaluate_async_script("arguments[0](false)")).to be false
          expect(@session.driver.evaluate_async_script("arguments[0](true)")).to be true
          expect(@session.driver.evaluate_async_script(%(arguments[0]({foo: "bar"})))).to eq("foo" => "bar")
        end
      end

      it "will timeout" do
        @session.using_wait_time(1) do
          expect do
            @session.driver.evaluate_async_script("var callback=arguments[0]; setTimeout(function(){callback(true)}, 4000)")
          end.to raise_error Ferrum::ScriptTimeoutError
        end
      end
    end

    it "can get the frames url" do
      @session.visit "/cuprite/frames"

      @session.within_frame(0) do
        expect(@session.driver.frame_url).to end_with("/cuprite/slow")
        if Capybara::VERSION.to_f < 3.0
          expect(@session.driver.current_url).to end_with("/cuprite/slow")
        else
          # current_url is required to return the top level browsing context in Capybara 3
          expect(@session.driver.current_url).to end_with("/cuprite/frames")
        end
      end
      expect(@session.driver.frame_url).to end_with("/cuprite/frames")
      expect(@session.driver.current_url).to end_with("/cuprite/frames")
    end

    it "waits for network idle" do
      @session.visit "/cuprite/show_cookies"
      expect(@session).not_to have_content("test_cookie")

      @session.click_button "Set cookie slow"
      @session.driver.wait_for_network_idle
      @session.refresh

      expect(@session).to have_content("test_cookie")
    end
  end
end
