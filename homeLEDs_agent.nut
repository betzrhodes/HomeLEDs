#require "Rocky.class.nut:1.1"
class ImpBase {

    rocky = null;
    waiting = null;
    ib_data = null;
    urlbase = null;

    constructor(rocky, urlbase = "/data") {

        this.rocky = rocky;
        this.waiting = {};
        this.ib_data = {};
        this.urlbase = urlbase;

        _ib_restore();

        rocky.on("GET", urlbase + "/impbase.js", _ib_javascript.bindenv(this));

        rocky.on("GET", urlbase, ib_get.bindenv(this)).onTimeout(_ib_get_timeout.bindenv(this), 60);
        rocky.on("GET", urlbase + "/(.*)", ib_get.bindenv(this)).onTimeout(_ib_get_timeout.bindenv(this), 60);
        rocky.on("POST", urlbase, ib_post.bindenv(this));
        rocky.on("POST", urlbase + "/.*", ib_post.bindenv(this));
        rocky.on("PUT", urlbase, ib_put.bindenv(this));
        rocky.on("PUT", urlbase + "/.*", ib_put.bindenv(this));
        rocky.on("PATCH", urlbase, ib_patch.bindenv(this));
        rocky.on("PATCH", urlbase + "/.*", ib_patch.bindenv(this));
        rocky.on("DELETE", urlbase, ib_delete.bindenv(this));
        rocky.on("DELETE", urlbase + "/.*", ib_delete.bindenv(this));
    }


    //--------------------[ Remote handlers ]----------------------------------

    // GET - Reading Data
    function ib_get(context) {

        local path = _map_path(context.req.path);
        local last_version = null;
        if ("version" in context.req.query) {
            try {
                if (context.req.query.version == "*") {
                    last_version = ib_data.version;
                } else {
                    last_version = context.req.query.version.tointeger();
                }
            } catch (e) {
                // Do nothing. Just assume version 0.

            }
        }
        if (last_version == null || last_version != ib_data.version) {
            // We don't have a version match so serve the results immediately
            context.setHeader("X-ImpBase-Version", ib_data.version);
            context.send(200, _ib_get_path(path), true);
            return;
        }
    }

    // PUT - Writing Data
    function ib_put(context) {

        // Clobber the data store with the new data
        local path = _map_path(context.req.path);
        put(path, context.req.body);

    }


    // PATCH - Updating Data
    function ib_patch(context) {

        local path = _map_path(context.req.path);
        if (context.req.body != null && typeof context.req.body != "table") {

            // Check the input data is a table
            context.send(400, "Body must be a JSON object");

        } else {

            local ptr = _ib_get_path(path);
            if (ptr != null && typeof ptr != "table") {

                context.send(400, "Existing data must be a table");

            } else {

                // Update the target node with the specified changes
                update(path, context.req.body);

            }

        }
    }


    // DELETE - Removing Data
    function ib_delete(context) {

        // Delete the data store contents
        local path = _map_path(context.req.path);
        remove(path);

    }

    // POST - Pushing Data
    function ib_post(context) {

        local path = _map_path(context.req.path);
        local autoid = push(path, context.req.body);

        // Send a unique result to this context
        context.setHeader("X-ImpBase-Version", ib_data.version);
        context.send(200, {"name": autoid}, true);

    }


    //--------------------[ Local handlers ]----------------------------------

    // GET - Reading Data
    function once(path) {

        // Retrieve the data from the data store
        return _ib_get_path(path);

    }

    function on(path, eventtype, callback) {

        // Register the callback for future changes
        if (!(path in waiting)) waiting[path] <- {};
        if (!(eventtype in waiting[path])) waiting[path][eventtype] <- [];
        waiting[path][eventtype].push(callback);

        // Call the callback for the initial value
        local val = _ib_get_path(path);
        callback(val);

        // Returns the callback for off() requests
        return callback;
    }

    function off(path = null, eventtype = null, callback = null) {
        if (path == null) {
            waiting <- {};
        } else if (eventtype == null) {
            waiting[path] <- {};
        } else if (callback == null) {
            waiting[path][eventtype] <- [];
        } else {
            foreach (path, types in waiting) {
                foreach (type, callbacks in waiting[path]) {
                    for (local i = callbacks.len()-1; i >= 0; i--) {
                        if (callbacks[i] == callback) {
                            server.log("Remove callback " + i)
                            callbacks.remove(i);
                        }
                    }
                }
            }
        }
    }


    // PUT - Writing Data
    function put(path, newData) {

        // Clobber the data store with the new data
        _ib_set_path(path, newData);

        // Persist to disk
        _ib_persist();

        // Distribute to all the waiting clients
        _ib_broadcast(path);

    }

    // UPDATE - Updating Data
    function update(path, newData) {

        if (newData != null && typeof newData != "table") {

            // Check the input data is a table
            throw "Body must be a JSON object";

        } else {

            local ptr = _ib_get_path(path);
            if (ptr == null || newData == null) {

                // If the path isn't pointing to anything or the new data is null then treat it like a put/set
                _ib_set_path(path, newData);

                // Set the return value
                ptr = newData;

            } else if (typeof ptr == "table") {

                // Patch the data store with the new changes
                foreach (k,v in newData) ptr[k] <- v;

            } else {

                // The existing data isn't a table
                throw "Existing data must be a table";

            }
        }

        // Persist to disk
        _ib_persist();

        // Distribute to all the waiting clients
        _ib_broadcast(path);

    }


    // DELETE - Removing Data
    function remove(path) {

        // Delete the data store contents
        put(path, null);

    }


    // POST - Pushing Data
    function push(path, newData) {

        local ptr = _ib_get_path(path);

        // Make sure the existing data is clean
        if (typeof ptr != "table") {
            ptr = {};
        }

        // Append the new data to the old
        local autoid = format("~%08x-%04x", time(), math.rand()%0x10000);
        ptr[autoid] <- newData;

        // Update the data store
        _ib_set_path(path, ptr);

        // Persist to disk
        _ib_persist();

        // Distribute to all the waiting clients
        _ib_broadcast(path);

        return autoid;
    }


    //--------------------[ Private functions ]---------------------------------


    // Timeout handler for GET long polling requests
    function _ib_get_timeout(context) {

        // Send the latest, unchanged values
        context.setHeader("X-ImpBase-Version", ib_data.version);
        context.send(204, "");
    }


    // Removes null nodes from the data tree
    // This may become a memory/stack issue in larger trees. Redo this function
    // when that happens.
    function _ib_clean_data(ptr) {
        local changed = false;
        if (typeof ptr == "table" || typeof ptr == "array") {
            foreach (k,v in ptr) {
                if (v == null) {
                    // Remove this null node
                    changed = true;
                    delete ptr[k];
                } else if ((typeof v == "table" || typeof v == "array") && v.len() == 0) {
                    // Remove this empty array/table
                    changed = true;
                    delete ptr[k];
                } else if (typeof v == "array") {
                    // Convert this array into a table
                    changed = true;
                    local newtable = {};
                    for (local i = 0; i < v.len(); i++) {
                        newtable[i.tostring()] <- v[i];
                    }
                    ptr[k] <- newtable;
                    _ib_clean_data(ptr[k]);
                } else {
                    // Move into the next node
                    changed = changed || _ib_clean_data(v);
                }
            }
        }

        return changed;
    }


    // Persist the current data to agent storage
    function _ib_persist() {

        // Remove null nodes for the tree
        while (_ib_clean_data(ib_data.root));

        // Increment the version number
        ib_data.version++;

        // Read the latest stored data and update it
        local persist = server.load();
        persist.impbase <- ib_data;
        server.save(persist);
    }


    // Restores the previously persisted data from disk
    function _ib_restore() {
        local persist = server.load();
        if ("impbase" in persist) {
            ib_data = persist.impbase;
        } else {
            ib_data = { "root" : null, "version" : -1 };
        }
    }


    // Set the subitem based on the path
    function _ib_set_path(req_path, new_data) {

        // Split out the path parts
        local pathparts = split(req_path, "/");
        // server.log("Setting " + req_path + " to " + new_data);

        // Loop through the data searching for the node
        local parent = ib_data, ptr = ib_data.root, p = 0, part = null, last_part = null;
        for (p = 0; p < pathparts.len(); p++) {
            part = pathparts[p];
            // server.log(format("Stepping into %s/%s (%s)", (last_part ? last_part : "~"), part, typeof ptr));

            if (new_data == null) {

                // Handle deletions slightly differently
                if (!(part in ptr)) {
                    // Can't delete a node that doesn't exist
                    return new_data;
                } else if (typeof ptr[part] != "table" && p < pathparts.len()-1) {
                    // We aren't at the last node in the path but are at the last node of the data
                    return new_data;
                }

            } else {

                if (typeof ptr != "table") {
                    if (last_part && parent) {
                        // We are missing or overriding a node
                        ptr = parent[last_part] <- {};
                    } else {
                        // We are missing or overriding the root node
                        ptr = ib_data.root = {};
                    }
                }
                if (!(part in ptr) || typeof ptr[part] != "table") {
                    // But we can create a new node that doesn't exist
                    ptr[part] <- {};
                }
            }

            parent = ptr;
            ptr = ptr[part];
            last_part = part;
        }

        if (parent == ib_data) {
            ib_data.root = new_data;
        } else {
            parent[pathparts.pop()] <- new_data;
        }

        // We have set the item
        return new_data;
    }


    // Extract the subitem based on the path
    function _ib_get_path(req_path) {

        // Parse out the path parts
        local pathparts = split(req_path, "/");

        // Loop through the data searching for the node
        local ptr = ib_data.root;
        foreach (part in pathparts) {
            if (part in ptr) ptr = ptr[part];
            else return null;
        }

        // We have the item
        return ptr;
    }


    // Broadcast the results specific to the caller's request
    function _ib_broadcast(changedPath = null) {

        imp.wakeup(0, function() {

            // Broadcast to all waiting connections
            foreach (context in Rocky.Context._contexts) {
                local path = _map_path(context.req.path);
                if (path.find(changedPath) != null || changedPath.find(path) != null) {
                    context.setHeader("X-ImpBase-Version", ib_data.version);
                    context.send(200, _ib_get_path(path), true);
                }
            }

            // And to all waiting callback functions
            foreach (path, types in waiting) {
                if (path.find(changedPath) != null || changedPath.find(path) != null) {
                    foreach (type, callbacks in waiting[path]) {
                        foreach (callback in callbacks) {
                            callback(_ib_get_path(path));
                        }
                    }
                }
            }

        }.bindenv(this))
    }


    // Converts a HTTP URL to a local path
    function _map_path(path) {

        local newPath = path.slice(urlbase.len());
        if (newPath == "") newPath = "/";
        return newPath;

    }


    // Responds with the Javascript library
    function _ib_javascript(context) {

        context.setHeader("Content-Type", "application/javascript");
        context.send(200, @"
            function ImpBase (rootPath) {

                // Properties
                var _root = this;
                var _path = null;

                // Private methods
                var _constructor = function(rootPath) {

                    // Setup the static _requests object for holding the callbacks
                    if (typeof ImpBase._requests == 'undefined') {
                        ImpBase._requests = {};
                    }

                    if (!rootPath) {
                        // Use the current window URL as the basis for the path, assuming its running in an agent
                        _path = window.location.protocol + '//' + window.location.hostname + '/' + window.location.pathname.split('/')[1] + '/data';
                    } else {
                        // Strip any trailing slashes
                        while (rootPath.slice(-1) == '/') rootPath = rootPath.slice(0, -1);
                        _path = rootPath;
                    }
                }

                var _isRoot = function() {
                    return (_root.toString() == _path);
                }

                var _ajax = function(method, url, data, callback) {
                    if (typeof data == 'function') {
                        callback = data;
                        data = null;
                    }
                    var method = method.toUpperCase();
                    var xmlhttp = new XMLHttpRequest();
                    xmlhttp.onreadystatechange = function(){
                        if (xmlhttp.readyState == XMLHttpRequest.DONE) {
                            if (typeof callback == 'function') {
                                var response = null;
                                if (xmlhttp.status == 200 && xmlhttp.getResponseHeader('Content-Type').indexOf('json') >= 0) {
                                    response = JSON.parse(xmlhttp.responseText);
                                } else {
                                    response = xmlhttp.responseText;
                                }
                                callback(xmlhttp.status, response, xmlhttp.getResponseHeader('X-ImpBase-Version'));
                            }
                        }
                    }
                    xmlhttp.open(method, url, true);

                    if (method == 'GET') {
                        xmlhttp.send();
                    } else {
                        xmlhttp.setRequestHeader('Content-Type', 'application/json');
                        xmlhttp.send(JSON.stringify(data));
                    }

                    return xmlhttp;
                }

                var _randomInt = function(min, max) {
                    return Math.random() * (max - min) + min;
                }



                // Protected methods
                this._setRoot = function(newRoot) {
                    return _root = newRoot;
                }


                // Public methods
                this.root = function() {
                    return _root;
                }

                this.child = function(path) {
                    if (path) {

                        // Strip the leading and trailing slashes off the new path and trailing slashes off the old path
                        while (path.slice(0, 1) == '/') path = path.slice(1);
                        while (path.slice(-1) == '/') path = path.slice(0, -1);
                        if (path == '') return this;

                        // Append the new path to the old path
                        var newPath = _path + '/' + path;
                        var newRef = new ImpBase(newPath);
                        newRef._setRoot(_root);
                        return newRef;
                    } else {
                        return this;
                    }
                }

                this.parent = function() {
                    if (_isRoot()) return this;
                    var newPath = _path.split('/').slice(0, -1).join('/');
                    var newRef = new ImpBase(newPath);
                    newRef._setRoot(_root);
                    return newRef;
                }

                this.key = function() {
                    if (_isRoot()) return null;
                    return _path.split('/').slice(-1)[0];
                }

                this.toString = function() {
                    return _path;
                }

                this.set = function(value, onComplete) {
                    _ajax('PUT', _path, value, onComplete);
                }

                this.update = function(value, onComplete) {
                    _ajax('PATCH', _path, value, onComplete);
                }

                this.remove = function(onComplete) {
                    _ajax('PUT', _path, null, onComplete);
                }

                this.push = function(value, onComplete) {
                    // Generate the autoid
                    var time = ('00000000' + Math.floor(Date.now() / 1000).toString(16)).slice(-8);
                    var rand = ('0000' + _randomInt(1, 0x10000).toString(16)).slice(-4);
                    var autoid = '~' + time + '-' + rand;

                    if (value != undefined) {
                        // Post the provided value as a new node
                        _ajax('PUT', _path + '/' + autoid, value, onComplete);
                    }

                    // Return an empty child node
                    return this.child(autoid);
                }

                this.on = function(eventtype, callback, cancelCallback, context, _version) {

                    var request = null;
                    switch (eventtype) {
                        case 'value':
                            var url = _path;
                            var context = context ? context : this;
                            if (_version != undefined) url += '?version=' + _version;
                            request = _ajax('GET', url, function(status, response, version) {
                                if (status == 200) {
                                    callback.bind(context)(new DataSnapshot(this, response));
                                    this.on(eventtype, callback, cancelCallback, context, version);
                                } else if (status == 204) {
                                    this.on(eventtype, callback, cancelCallback, context, version);
                                } else if (cancelCallback) {
                                    if (eventtype in ImpBase._requests && callback in ImpBase._requests[eventtype]) {
                                        delete ImpBase._requests[eventtype][callback];
                                    }
                                    cancelCallback.bind(context)(status);
                                }
                            }.bind(this));
                    }

                    // Store the request for later cancelling with off()
                    if (request) {
                        if (!(eventtype in ImpBase._requests)) ImpBase._requests[eventtype] = {};
                        ImpBase._requests[eventtype][callback] = request;
                    }
                    return callback;
                }

                this.off = function(eventtype, callback) {
                    if (eventtype in ImpBase._requests && callback in ImpBase._requests[eventtype]) {
                        ImpBase._requests[eventtype][callback].abort();
                    }
                }

                this.once = function(eventtype, successCallback, failureCallback, context) {

                    var request = null;
                    switch (eventtype) {
                        case 'value':
                            var url = _path;
                            var context = context ? context : this;
                            request = _ajax('GET', url, function(status, response, version) {
                                if (status == 200) {
                                    successCallback.bind(context)(new DataSnapshot(this, response));
                                } else if (failureCallback) {
                                    failureCallback.bind(context)(status);
                                }
                            }.bind(this));
                    }
                }


                // Call the constructor
                _constructor(rootPath);
            }

            function DataSnapshot(ref, val) {

                // Properties
                this._ref = ref;
                this._val = val;

                // Private methods
                var _constructor = function() {
                }

                // Public methods
                this.exists = function() {
                    return this._val != null;
                }

                this.val = function() {
                    return this._val;
                }

                this.child = function(childPath) {
                    var newRef = this._ref.child(childPath);
                    var nodes = childPath.split('/');
                    var newVal = this._val;
                    for (var nodeid in nodes) {
                        var node = nodes[nodeid];
                        if (node == '') {
                            continue;
                        } else if (newVal != null && typeof newVal == 'object' && node in newVal) {
                            newVal = newVal[node];
                        } else {
                            newVal = null;
                            break;
                        }
                    }
                    return new DataSnapshot(newRef, newVal);
                }

                this.forEach = function(childAction) {
                    for (var key in this._val) {
                        var ret = childAction(this.child(key));
                        if (ret === true) return true;
                    }
                    return false;
                }

                this.hasChild = function(childPath) {
                    return this.child(childPath).exists();
                }

                this.hasChildren = function() {
                    return this.numChildren() > 0;
                }

                this.numChildren = function() {
                    if ((this._val != null) && (typeof this._val == 'object')) {
                        return Object.keys(this._val).length;
                    } else {
                        return 0;
                    }
                }

                this.key = function() {
                    return this._ref.key();
                }

                this.ref = function() {
                    return this._ref;
                }


                // Call the constructor
                _constructor();

            }
        ");
    }


}

// ------------------------ Configuation ---------------------------
app <- Rocky(); //create an instance of rocky for impbase and webpage rendering
impbase <- ImpBase(app, "/data"); //create an instance of impbase - db for realtime functionality

led <- { "state" : 0 }; //sets default LED state to OFF
local settings = impbase.once("/"); //gets data from ImpBase
if (!("state" in settings)) {
    impbase.put("/", led); //stores default to impbase
}

// -------------------------- Run Time ---------------------------
device.on("getState" function(msg) {
    local state = impbase.once("/state")
    if(typeof state == "float" || typeof state == "integer") {
       device.send("state", state); //sends state to device
    }
});

impbase.on("/", "value", function(snapshot) {
    server.log("impbase change "+http.jsonencode(snapshot));
    if ("state" in snapshot) {
        device.send("state", snapshot.state);
    }
});

app.get("/", function(context) {
    context.send(200, html); //render HTML to agent's URL
});

html <- @"
        <!DOCTYPE html>
        <html lang='en'>
          <head>
            <meta charset='utf-8'>
            <meta http-equiv='X-UA-Compatible' content='IE=edge'>
            <meta name='viewport' content='width=device-width, initial-scale=1'>
            <meta name='description' content>
            <meta name='author' content>
            <title>HomeLEDs</title>

            <style>
              h1 {
                text-align: center;
                font-size: 36px;
              }

              button {
                font-size: 36px;
                border-radius: 4px;
                padding: 2% 5%;
                margin: 0 5%;
              }

              .buttons {
                margin: auto;
                width: 80%;
                text-align: center;
              }

              #slider {
                width: 60%;
                margin: 2% auto 4%;
              }

              /*! jQuery UI - v1.11.4 - 2015-04-03
               * http://jqueryui.com
               * not whole lib - just the styles used by the slider
               */
              .ui-corner-all,
              .ui-corner-top,
              .ui-corner-left,
              .ui-corner-tl {
                border-top-left-radius: 4px;
              }
              .ui-corner-all,
              .ui-corner-top,
              .ui-corner-right,
              .ui-corner-tr {
                border-top-right-radius: 4px;
              }
              .ui-corner-all,
              .ui-corner-bottom,
              .ui-corner-left,
              .ui-corner-bl {
                border-bottom-left-radius: 4px;
              }
              .ui-corner-all,
              .ui-corner-bottom,
              .ui-corner-right,
              .ui-corner-br {
                border-bottom-right-radius: 4px;
              }
              .ui-widget-content {
                border: 1px solid #aaaaaa;
                background: #ffffff;
                color: #222222;
              }
              .ui-widget {
                font-family: Verdana,Arial,sans-serif;
                font-size: 1.1em;
              }
              .ui-slider-horizontal {
                height: .8em;
              }
              .ui-slider-horizontal .ui-slider-handle {
                top: -.3em;
                margin-left: -.6em;
              }
              .ui-slider {
                position: relative;
                text-align: left;
              }
              .ui-slider .ui-slider-handle {
                position: absolute;
                z-index: 2;
                width: 1.2em;
                height: 1.2em;
                cursor: default;
                -ms-touch-action: none;
                touch-action: none;
              }
              .ui-state-default,
              .ui-widget-content .ui-state-default,
              .ui-widget-header .ui-state-default {
                border: 1px solid #d3d3d3;
                background: #e6e6e6;
                font-weight: normal;
                color: #555555;
              }
              .ui-state-active,
              .ui-widget-content .ui-state-active,
              .ui-widget-header .ui-state-active {
                border: 1px solid #aaaaaa;
                background: #ffffff;
                font-weight: normal;
                color: #212121;
              }
            </style>
          </head>
          <body>

            <h1>DIMMER CONTROL</h1>
            <div id='slider'></div>
            <br>
            <div class='buttons'>
              <button id='on' data-state='1'>ON</button>
              <button id='off' data-state='0'>OFF</button>
            </div>


            <!-- jQuery -->
            <script src='https://ajax.googleapis.com/ajax/libs/jquery/1.11.1/jquery.min.js'></script>
            <script src='https://cdnjs.cloudflare.com/ajax/libs/jqueryui/1.11.2/jquery-ui.min.js'></script>
            <SCRIPT src='https://agent.electricimp.com/Cq0zvg1JNhJP/data/impbase.js'></SCRIPT>
            <!-- JavaScript File -->
            <script>
              $(document).ready(function() {
                var IB = new ImpBase();
                var sliderState = 0;

                getState(initialzeSlider);

                function getState(callback) {
                    IB.child('state').once('value', function(snapshot) {
                            callback(snapshot.val());
                        }, function(error) {
                            console.log('Error:', error);
                    })
                }

                function sendState(state) {
                    if(state != sliderState) {
                        console.log('Sending '+ sliderState +' to IB at ' + new Date());
                        IB.update({ 'state' : sliderState });
                    }
                }

                function initialzeSlider(state) {
                    $('#slider').slider({'value' : state*100});
                    openListeners();
                }

                function openListeners() {
                    $('#slider').on('slidechange', function(e, ui) {
                        sliderState = ui.value / 100;
                        getState(sendState);
                    });
                    $('button').on('click', translateButtonClick);
                    IB.on('value', handleIBChange)
                }

                function translateButtonClick(e){
                  var state = e.currentTarget.dataset.state;
                  setSlider(state);
                }

                function setSlider(state) {
                  $('#slider').slider('option', 'value', state*100);
                }

                function handleIBChange(snapshot) {
                    console.log('IB change registered. Snapshot value: ' + JSON.stringify(snapshot.val()) + ' Time Received: ' + new Date());

                    if('state' in snapshot.val() && snapshot.val().state != sliderState ) {
                        setSlider(snapshot.val().state);
                    }
                }

              })
            </script>

          </body>
        </html>
"