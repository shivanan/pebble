(function() {
  var app, express, generateUser, getUserDetails, io, mustache, rc, redis, redis_store, sessions, tmpl, viewPath;
  express = require('express');
  mustache = require("./mustache.js");
  io = require('socket.io');
  redis = require('redis');
  redis_store = require('connect-redis')(express);
  tmpl = {
    compile: function(source, options) {
      if ('string' === typeof source) {
        return function(options) {
          var compile_options, template;
          options.locals = options.locals || {};
          options.partials = options.partials || {};
          if (options.body) {
            locals.body = options.body;
          }
          compile_options = {};
          template = mustache.compile(source, compile_options);
          return template(options.locals, options.partials);
        };
      } else {
        return source;
      }
    },
    render: function(template, options) {
      template = this.compile(template, options);
      return template(options);
    }
  };
  app = module.exports = express.createServer();
  viewPath = function() {
    return __dirname + '/views';
  };
  app.configure(function() {
    app.use(express.bodyParser());
    app.use(express.cookieParser());
    app.use(express.session({
      secret: 'ze zecret goes here',
      store: new redis_store()
    }));
    app.use(express.methodOverride());
    app.use(app.router);
    app.set('views', viewPath());
    app.set('view options', {
      layout: false
    });
    app.register('.html', tmpl);
    return app.use(express.errorHandler({
      dumpExceptions: true,
      showStack: true
    }));
  });
  app.use(express.static(__dirname + '/public'));
  sessions = {};
  rc = redis.createClient();
  generateUser = function(cb) {
    return rc.incr('userkey', function(e, obj) {
      return cb(obj);
    });
  };
  getUserDetails = function(uk, cb, err_cb) {
    return rc.hgetall('uk:' + uk, function(err, obj) {
      if (err != null) {
        if (err_cb != null) {
          return err_cb(err);
        }
      } else {
        return cb(obj);
      }
    });
  };
  io = io.listen(app);
  io.sockets.on('connection', function(socket) {
    socket.on('connect', function(data) {
      var chid;
      chid = data.chid;
      if (!sessions[chid]) {
        sessions[chid] = [];
      }
      return sessions[chid].push(socket);
    });
    return socket.on('message', function(data) {
      var chid, s, _i, _len, _ref, _results;
      chid = data.chid;
      rc.lpush('session:' + chid, JSON.stringify(data));
      if (sessions[chid] != null) {
        _ref = sessions[chid];
        _results = [];
        for (_i = 0, _len = _ref.length; _i < _len; _i++) {
          s = _ref[_i];
          _results.push(s.emit('message', data));
        }
        return _results;
      }
    });
  });
  app.get('/', function(req, resp) {
    return resp.render('index.html');
  });
  app.get('/:chid/history', function(req, resp) {
    var chid, history;
    chid = req.params.chid;
    history = [];
    return rc.lrange('session:' + chid, 0, 100, function(e, objlist) {
      var obj, _i, _len;
      if (e != null) {
        console.log('Error', e);
      } else {
        for (_i = 0, _len = objlist.length; _i < _len; _i++) {
          obj = objlist[_i];
          history.push(JSON.parse(obj));
        }
      }
      return resp.json(history);
    });
  });
  app.get('/updateuser/:userkey', function(req, resp) {
    var name;
    if (!(req.session.userkey != null)) {
      resp.json({
        "error": "no such user"
      }, 400);
    }
    name = req.query.name;
    rc.hset('uk:' + req.session.userkey, 'name', name);
    return getUserDetails(req.session.userkey, function(obj) {
      req.session.user = obj;
      return resp.json({
        "status": "ok"
      }, 200);
    }, function(err) {
      console.log('error', err);
      return resp.json(err, 400);
    });
  });
  app.get('/:chid', function(req, resp) {
    var handler;
    handler = function(req, resp) {
      var ch_id, history;
      ch_id = req.params.chid;
      history = [];
      return rc.lrange('session:' + ch_id, 0, 10, function(e, objlist) {
        var obj, _i, _len, _ref;
        if (e != null) {
          console.log('Error', e);
        } else {
          for (_i = 0, _len = objlist.length; _i < _len; _i++) {
            obj = objlist[_i];
            history.push({
              'item': obj
            });
          }
        }
        return resp.render('ch.html', {
          locals: {
            'chid': ch_id,
            'userkey': req.session.userkey,
            'user': (_ref = req.session.user) != null ? _ref : {}
          }
        });
      });
    };
    if (!(req.session.userkey != null)) {
      console.log('generating userkey');
      return generateUser(function(key) {
        req.session.userkey = key;
        return handler(req, resp);
      });
    } else {
      console.log('got user key', req.session.userkey);
      return handler(req, resp);
    }
  });
  app.listen(81);
}).call(this);
