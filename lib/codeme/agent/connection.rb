require 'socket'

require 'websocket/driver'
require 'aasm'

require 'codeme/common'

require 'codeme/agent/config'
require 'codeme/agent/component'
require 'codeme/agent/request_pool'

module Codeme
  module Agent
    class SystemHandler < Handler
      def resolve(data)
        connection.logger.debug "echo data: #{data}"
      end
    end

    class RFIDHandler < Handler
      def resolve(data)
        connection = self.env[:connection]
        connection.logger.debug "echo data: #{data}"
        connection.request_pool.add_response(Response.new(self.type, data))
      end
    end
  end
end




module Codeme
  module Agent
    class Connection < Component
      include AASM

      aasm do
        state :init, initial: true
        state :connecting
        state :auth_pending
        state :ready

        event :connect do
          transitions from: :init, to: :connecting, after: Proc.new { logger.info "Start connecting" }
        end
        
        event :auth_request do
          transitions from: :connecting, to: :auth_pending, after: Proc.new { logger.info "Sending authentication request" }
        end
        
        event :auth_success do
          transitions from: :auth_pending, to: :ready, after: Proc.new { logger.info "Authentication finished" }
        end

        event :reset do
          transitions to: :init, after: Proc.new { logger.info "Connection state reset" }
        end
      end


      attr_reader :url
      attr_reader :request_pool

      def initialize(master, host, port)
        super()
        @master = master
        @url = "#{Config.use_ssl ? "wss" : "ws"}://#{host}:#{port}"
        self.reset
        
        @host = host
        @port = port
        @tag = 0
        
        @request_pool = RequestPool.new
        @request_pool.set_handler(:request_timedout, method(:handle_request_timedout))
        @request_pool.set_handler(:request_meet, method(:handle_request_meet))
        @request_pool.set_handler(:send_request, method(:handle_send_request))
        
        env_data = {connection: self}
        Resolver.config do
          handle Type::REBOOT,  SystemHandler, env_data
          handle Type::RFID_NUMBER,  RFIDHandler, env_data
        end
      end

      def handle_request_timedout(req)
        @master.send_event(EVENT_CONNECTION_NOT_READY, "Connection not ready for #{req.ev_type}:#{req.ev_body}")
      end

      def handle_request_meet(req, res)
        logger.debug "Got packet: #{res.ev_type}: #{res.ev_body}"
        @master.send_event(EVENT_BEEP, ["ok", "no"].sample)
      end

      def handle_send_request(req)
        if self.ready?
          @driver.binary(Packet.new(req.ev_type, @tag, req.wrap_body).dump)
          true
        else
          false
        end
      end

      # override
      def worker_loop
        loop do
          @request_pool.update
          ready = @selector.select(1)
          ready.each { |m| m.value.call } if ready
          if @io.nil?
            @io = try_create_socket
            if @io
              # socket io opened
              register_socket_io
              # start ws
              start_web_driver
            end
          end
        end
      end

      def send_auth_request
        # TODO: other types of auth 
        @driver.binary(Packet.new(Type::AUTH_TOKEN, 0, [@master.serial_number,Config.token].join(",")).dump)
      end

      def start_web_driver
        @driver = WebSocket::Driver.client(self)
        @driver.on :open, proc { |e| 
          logger.info "Server opened"
          self.auth_request
          send_auth_request
        }
        @driver.on :close, proc { |e| 
          logger.info "Server closed"
          close_socket_io
          self.reset
        }
        @driver.on :message, proc { |e|
          pkt = Packet.load(e.data)
          process_packet(pkt) if pkt
        }
        @driver.start
        self.connect
      end

      def register_socket_io
        _monitor = @selector.register(@io, :r)
        _monitor.value = proc do
          msg = @io.recv_nonblock(65535)
          if msg.empty?
            # socket closed
            close_socket_io
            self.reset
          else
            @driver.parse(msg)
          end
        end
      end

      def try_create_socket
        logger.info "try to re-open socket..."
        TCPSocket.new(@host, @port)
      rescue
        nil
      end

      def close_socket_io
        logger.info "Socket IO Closed and Deregistered"
        @selector.deregister(@io)
        @io.close
        @io = nil
      end

      def write(string)
        @io.write(string)
      rescue
        logger.error "Write Error"
        close_socket_io
        self.reset
      end

      def process_packet(pkt)
        if self.auth_pending?
          if pkt.type == Type::AUTH_RESPONSE
            if pkt.body == "0" # true
              @tag = pkt.tag
              logger.info "Authentication Success, connection established, tag = #{@tag}"
              self.auth_success
            else
              logger.error "Authentication failed. Delay for 3 seconds"
              sleep 3
            end
          else
            logger.error "Authentication error: Not an authentication result packet"
          end
        else
          if pkt.tag == @tag || pkt.tag == 0
            Resolver.resolve(pkt) 
          else
            logger.debug "Tag mismatch packet: tag: #{pkt.tag}, type: #{pkt.type}"
          end
        end
      end

      def process_event(ev_type, ev_body)
        case ev_type
        when EVENT_CARD_DATA
          req = Request.new(Type::RFID_NUMBER , ev_body, ev_body)
          @request_pool.add_request(req)
        end
      end
    end
  end
end

