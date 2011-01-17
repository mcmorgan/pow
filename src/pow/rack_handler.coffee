fs   = require "fs"
nack = require "nack"

{LineBuffer} = require "nack/util"
{join, dirname, basename} = require "path"
{exec } = require "child_process"

sourceScriptEnv = (script, callback) ->
  command = """
    source #{script} > /dev/null;
    #{process.execPath} -e 'JSON.stringify(process.env)'
  """
  exec command, cwd: dirname(script), (err, stdout) ->
    return callback err if err
    try
      callback null, JSON.parse stdout
    catch exception
      callback exception

getEnvForRoot = (root, callback) ->
  path = join root, ".powrc"
  fs.stat path, (err) ->
    if err
      callback null, {}
    else
      sourceScriptEnv path, callback

bufferLines = (stream, callback) ->
  buffer = new LineBuffer stream
  buffer.on "data", callback
  buffer

module.exports = class RackHandler
  constructor: (@configuration, @root, callback) ->
    @logger = @configuration.getLogger join "apps", basename @root
    @readyCallbacks = []

    createServer = =>
      @app = nack.createServer join(@root, "config.ru"), @env

    processReadyCallbacks = =>
      readyCallback() for readyCallback in @readyCallbacks
      @readyCallbacks = []

    installLogHandlers = =>
      bufferLines @app.pool.stdout, (line) => @logger.info line
      bufferLines @app.pool.stderr, (line) => @logger.warning line

      @app.pool.on "worker:spawn", (process) =>
        @logger.debug "nack worker #{process.child.pid} spawned"

      @app.pool.on "worker:exit", (process) =>
        @logger.debug "nack worker exited"

    getEnvForRoot @root, (err, @env) =>
      if err
        callback? err
      else
        createServer()
        installLogHandlers()
        callback null, @
        processReadyCallbacks()

  ready: (callback) ->
    if @app
      callback()
    else
      @readyCallbacks.push callback

  handle: (pausedReq, res, next, resume) ->
    @ready => @restartIfNecessary =>
      pausedReq.proxyMetaVariables =
        SERVER_PORT: @configuration.dstPort.toString()
      try
        @app.handle pausedReq, res, next
      finally
        resume()

  quit: (callback) ->
    if @app
      @app.pool.once "exit", callback if callback
      @app.pool.quit()
    else
      callback?()

  restartIfNecessary: (callback) ->
    fs.unlink join(@root, "tmp/restart.txt"), (err) =>
      if err
        callback()
      else
        @quit callback
