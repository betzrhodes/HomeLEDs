#require "Rocky.class.nut:1.0.0"

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
            <!-- JavaScript File -->
            <script>
              $(document).ready(function() {
                var agentURL = 'YOUR AGENT URL HERE'
                getState(initialzeSlider);

                $('button').on('click', translateButtonClick);

                function translateButtonClick(e){
                  var state = e.currentTarget.dataset.state;
                  sendState(state);
                  setSlider(state);
                }

                function sendState(state) {
                  $.ajax({
                    url : agentURL + '/state',
                    type: 'POST',
                    data: JSON.stringify({ 'state' : state }),
                    success : function(response) {
                      console.log(response)
                    }
                  });
                }

                function getState(callback) {
                  $.ajax({
                    url : agentURL + '/state',
                    type: 'GET',
                    success : function(response) {
                      if (callback) {callback(response.state)}
                    }
                  });
                }

                function setSlider(state) {
                  $('#slider').slider('option', 'value', state*100);
                }

                function initialzeSlider(state) {
                    $('#slider').slider({'value' : state*100});
                    $('#slider').on('slidechange', function(e, ui) {
                      sendState(ui.value / 100);
                    })
                }

              })
            </script>

          </body>
        </html>
"

// -------------------------- Run Time ---------------------------

app <- Rocky(); //create an instance of rocky - sets up framework for a restful API
led <- { "state" : 0 }; //sets default LED state to OFF

local settings = server.load(); //gets stored state from server
if (settings.len() != 0) {led = settings}; //if server has data then update current state
device.send("state", led.state); //sends state to device

app.get("/", function(context) {
    context.send(200, html); //render HTML to agent's URL
})

app.get("/state", function(context) {
    context.send({ state = led.state }) //send current state to website
})

app.post("/state", function(context) {
    local data = http.jsondecode(context.req.body) //turn JSON data into table
    led.state = data.state.tofloat();
    local saved = server.save(led); //store state to server
    device.send("state", led.state); //update device with state from webpage
    context.send("OK"); //send response back to webpage
    
    server.log("received new led level of " + led.state);
    if (saved == 0) { 
        server.log("State stored to server");
    } else {
        server.log("Server save failed. Error: " + err.tostring());
    }
});
