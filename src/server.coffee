fs = require 'fs'
async = require 'async'
rpcError = require('./rpcError.coffee')

Function::execute = ->
  if arguments[0] instanceof Array
    this.apply null, arguments[0]
  else
    args = this.toString().match(/function[^(]*\(([^)]*)\)/)[1].split(/,\s*/)
    named_params = arguments[0]
    params = [].slice.call arguments, 0, -1
    if params.length < args.length
      for arg in args
        params.push named_params[arg]
    this.apply(null, params)

class server

  methods: {}

  exposeModule: (name, module) ->
    for method of module
      @methods[name + '.' + method] = module[method]

  expose: (name, func) ->
    @methods[name] = func

  checkAuth: (method, params, headers) ->
    true

  loadModules: (modulesDir, callback) ->
    fs.readdir modulesDir, (err, modules) =>
      if (!err)
        for moduleFile in modules
          module = require modulesDir + moduleFile
          moduleName = moduleFile.replace('.coffee', '').replace('.js', '')
          @exposeModule moduleName, module
      if callback
        callback()

  handleRequest: (json, headers, reply) ->
    try
      requests = JSON.parse(json)
    catch error
      return reply rpcError.invalidRequest()

    handleNotification = (request) =>
      res = @checkAuth(request.method, request.params, headers)
      if res is true && request.method && @methods[request.method]
        method = @methods[request.method]
        try
          method.execute request.params
        finally
          #nothing there

    batch = 1
    if requests not instanceof Array
      if !requests.id #for single notification
        handleNotification requests
        return reply null
      requests = [requests]
      batch = 0

    calls = []
    for request in requests
      if !request.id #for notification in batch
        handleNotification request
        continue

      if !request.method
        calls.push (callback) =>
          callback null, rpcError.invalidRequest request.id
        continue

      if !@methods[request.method]
        calls.push (callback) =>
          callback null, rpcError.methodNotFound request.id
        continue

      res = @checkAuth(request.method, request.params, headers)
      if res is not true
        calls.push (callback) =>
          callback null, rpcError.abstract "AccessDenied", -32000, request.id
        continue

      ((req, method) ->
        calls.push (callback) ->
          result = null
          try
            result = method.execute req.params
          catch error
            if error instanceof Error
              return callback null, rpcError.abstract error.message, -32099, req.id #if method throw common Error
            else
              return callback null, error #if method throw rpcError

          response =
            jsonrpc: '2.0'
            result: result || null
          if req.id
            response.id = req.id

          callback null, response)(request, @methods[request.method])

    async.parallel calls, (err, response) ->
      if response.length is 0
        return reply null
      if !batch && response instanceof Array
        response = response[0]
      reply response


module.exports = server
