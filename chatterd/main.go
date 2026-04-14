package main

import (
	"log"
        "context"
	"github.com/jackc/pgx/v4/pgxpool"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
)

type Route struct {
    HTTPMethod string
    URLPath    string
    URLHandler echo.HandlerFunc
}

var routes = []Route {
		// {"GET", "/", top},	
		{"POST", "/llmprompt/", llmprompt},
		{"POST", "/llmchat/", llmchat},
		{"POST", "/llmtools/", llmtools},
    		{"GET", "/weather/", weather},
		{"POST", "/llmprep/", llmprep},
	        {"GET", "/getchatts/", getchatts},
                {"POST", "/postchatt/", postchatt},
		{"GET", "/getmaps/", getmaps},
   		{"POST", "/postmaps/", postmaps},
		{"POST", "/adduser/", adduser},
		{"POST", "/postauth/", postauth},
}

var background = context.Background()
var chatterDB *pgxpool.Pool

func main() {
	var err error
	chatterDB, err = pgxpool.Connect(background, "host=localhost user=chatter password=chattchatt dbname=chatterdb")
	if err != nil { panic(err) }
	server := echo.New()
	server.HideBanner = true
	for _, route := range routes {
		server.Match([]string{route.HTTPMethod}, route.URLPath, route.URLHandler)
	}
	server.Pre(middleware.AddTrailingSlash())

	log.Fatal(server.StartTLS(":443",
		"/home/ubuntu/reactive/chatterd.crt",
		"/home/ubuntu/reactive/chatterd.key"))

	
}

