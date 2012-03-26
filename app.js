(function() {
  var EH, app, express, fillMessageData, generateID, generateUser, getUserDetails, io, mustache, pushMessage, rc, redis, redis_store, sessions, tmpl, viewPath;
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
  EH = function(resp) {
    return function(e) {
      return resp.json(e, 500);
    };
  };
  generateID = function(prefix, err, cb) {
    console.log('my err', err);
    return rc.incr(prefix, function(e, uk) {
      if (e != null) {
        return err(e);
      } else {
        return cb(uk);
      }
    });
  };
  generateUser = function(e, cb) {
    return generateID('userkey', e, function() {
      return rc.incr('userkey', function(e, uk) {
        rc.hset('uk:' + uk, 'userkey', uk);
        rc.lpush('global.users', uk);
        return cb(uk);
      });
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
  fillMessageData = function(messages, cb) {
    var msg, multi, uklist, _i, _len;
    multi = rc.multi();
    uklist = {};
    for (_i = 0, _len = messages.length; _i < _len; _i++) {
      msg = messages[_i];
      if (uklist[msg.userkey] != null) {
        continue;
      }
      multi.hgetall('uk:' + msg.userkey);
      uklist[msg.userkey] = '1';
    }
    return multi.exec(function(err, replies) {
      var i, msg, r, ukmap, _j, _k, _len2, _len3;
      i = 0;
      console.log('multireplies', replies);
      ukmap = {};
      for (_j = 0, _len2 = replies.length; _j < _len2; _j++) {
        r = replies[_j];
        ukmap[r.userkey] = r.name;
      }
      for (_k = 0, _len3 = messages.length; _k < _len3; _k++) {
        msg = messages[_k];
        messages[i].username = ukmap[messages[i].userkey];
        i += 1;
      }
      return cb(messages);
    });
  };
  pushMessage = function(message) {
    var chid;
    chid = message.chid;
    if (!(sessions[chid] != null)) {
      return;
    }
    return fillMessageData([message], function(messages) {
      var m, s, _i, _len, _ref, _results;
      _ref = sessions[chid];
      _results = [];
      for (_i = 0, _len = _ref.length; _i < _len; _i++) {
        s = _ref[_i];
        _results.push((function() {
          var _j, _len2, _results2;
          _results2 = [];
          for (_j = 0, _len2 = messages.length; _j < _len2; _j++) {
            m = messages[_j];
            _results2.push(s.emit('message', m));
          }
          return _results2;
        })());
      }
      return _results;
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
      var chid;
      chid = data.chid;
      rc.lpush('session:' + chid, JSON.stringify(data));
      return pushMessage(data);
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
      var obj;
      if (e != null) {
        console.log('Error', e);
        resp.json(e);
      } else {
        objlist = (function() {
          var _i, _len, _results;
          _results = [];
          for (_i = 0, _len = objlist.length; _i < _len; _i++) {
            obj = objlist[_i];
            _results.push(JSON.parse(obj));
          }
          return _results;
        })();
        return fillMessageData(objlist, function(messages) {
          var obj, _i, _len;
          for (_i = 0, _len = messages.length; _i < _len; _i++) {
            obj = messages[_i];
            history.push(obj);
          }
          return resp.json(history);
        });
      }
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
      return generateUser(EH(resp), function(key) {
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
