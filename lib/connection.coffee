Readable = require('readable-stream').Readable
DataInputStream = require './data-input-stream'
Call = require './call'
{DataOutputStream, DataOutputBuffer} = require './output-buffer'
debug = (require 'debug') 'hbase-connection'
net = require 'net'
{EventEmitter} = require 'events'


HEADER = new Buffer "HBas"
CALL_TIMEOUT = 5000
connectionId = 0

ProtoBuf = require("protobufjs")
ByteBuffer = require 'protobufjs/node_modules/bytebuffer'

builder = ProtoBuf.loadProtoFile("#{__dirname}/../proto/Client.proto")
rpcBuilder = ProtoBuf.loadProtoFile("#{__dirname}/../proto/RPC.proto")

proto = builder.build()
rpcProto = rpcBuilder.build()

{ClientService, GetRequest} = proto
{ConnectionHeader, RequestHeader, ResponseHeader} = rpcProto


module.exports = class Connection extends EventEmitter
	constructor: (options) ->
		@id = connectionId++
		@callId = 1
		@calls = {}
		@header = null
		@socket = null
		@tcpNoDelay = no
		@tcpKeepAlive= yes
		@calls = {}
		@address =
			host: options.host
			port: options.port
		@name = "connection(#{@address.host}:#{@address.port}) id: #{@id}"
		@_connected = no
		@_socketError = null
		@_callNums = 0
		@setupIOStreams()


	setupIOStreams: () =>
		debug "connecting to #{@name}"
		@setupConnection()
		@in = new DataInputStream @socketReadable
		@out = new DataOutputStream @socket

		@in.on 'messages', @processMessages

		@socket.on 'connect', () =>
			debug "connected to #{@name}"
			@writeHead()
			ch = new ConnectionHeader
				serviceName: "ClientService"
			header = ch.encode().toBuffer()
			@out.writeInt header.length
			@out.write header
			@_connected = yes

			impl = (method, req, done) =>
				reflect = builder.lookup method
				reqHeader = new RequestHeader
					callId: @callId++
					requestParam: yes
					methodName: reflect.name
				reqHeaderBuffer = reqHeader.toBuffer()

				@out.writeDelimitedBuffers reqHeaderBuffer, req.toBuffer()
				@calls[reqHeader.callId] = new Call reflect.resolvedResponseType.clazz, reqHeader, CALL_TIMEOUT, done

			@rpc = new ClientService impl

			@emit 'connect'


	processMessages: (messages) =>
		header = ResponseHeader.decode messages[0]
		unless call = @calls[header.callId]
			debug "Invalid callId #{header.callId}"
			return

		return call.complete header.exception if header.exception

		call.complete null, call.responseClass.decode messages[1]


	writeHead: () =>
		b1 = new Buffer 1
		b1.writeUInt8 0, 0
		b2 = new Buffer [1]
		b2.writeUInt8 80, 0
		@out.write Buffer.concat [HEADER, b1, b2]


	setupConnection: () =>
		ioFailures = 0
		timeoutFailures = 0
		@socket = net.connect @address
		@socketReadable = @socket

		if typeof @socketReadable.read isnt "function"
			@socketReadable = new Readable()
			@socketReadable.wrap @socket
			# ignore error event
			@socketReadable.on "error", utility.noop

		@socket.setNoDelay @tcpNoDelay
		@socket.setKeepAlive @tcpKeepAlive

		@socket.on "timeout", @_handleTimeout.bind @
		@socket.on "close", @_handleClose.bind @

		# when error, response all calls error
		@socket.on "error", @_handleError.bind @

		# send ping
		#@_pingTimer = setInterval @sendPing.bind @, @pingInterval


	_handleClose: () =>
		console.log "_handleClose", arguments


	_handleError: () =>
		console.log "_handleError", arguments


	_handleTimeout: () =>
		console.log "_handleTimeout", arguments


class Service
	constructor: (service, impl) ->
		r = builder.lookup service
		client = new r.clazz impl
		r.children.forEach (child) =>
			@[child.name] = (req, done) ->
				clazz = child.resolvedRequestType.clazz
				req = new clazz req if req not instanceof clazz
				client[child.name].call client, req, done


class ClientService extends Service
	constructor: (impl) ->
		super 'ClientService', impl


