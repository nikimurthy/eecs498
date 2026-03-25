package main

import (
    "log"
    "net/http"
    "net/http/httputil"
    "net/url"
    "time"
    "github.com/labstack/echo/v4"
    "bufio"
    "bytes"
    "encoding/json"
    "errors"
    "fmt"
    "io"
    "regexp"
    "strings"
)
type OllamaMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type OllamaRequest struct {
	AppID    string    `json:"appID"`
	Model    string    `json:"model"`
	Messages []OllamaMessage `json:"messages"`
	Stream   bool      `json:"stream"`
}

type OllamaResponse struct {
	Model     string  `json:"model"`
	Message   OllamaMessage `json:"message"`
}

type Chatt struct {
    Name  string    `json:"name"`
    Message   string    `json:"message"`
    Id        string    `json:"id"`
    Timestamp time.Time `json:"timestamp"`
}

func llmprep(c echo.Context) error {
        err := errors.New("")
        var ollamaRequest OllamaRequest

        if err = c.Bind(&ollamaRequest); err != nil {
                return logClientErr(c, http.StatusUnprocessableEntity, err)
        }

        if len(ollamaRequest.AppID) == 0 {
                return logClientErr(c, http.StatusUnprocessableEntity,
                        fmt.Errorf("invalid appID: %s", ollamaRequest.AppID))
        }

        // clear all old messages for this appID
        _, err = chatterDB.Exec(background, `DELETE FROM chatts WHERE appid = $1`,
                ollamaRequest.AppID)
        if err != nil {
                return logServerErr(c, err)
        }

        // insert each system message into the database
        for _, msg := range ollamaRequest.Messages {
                _, err = chatterDB.Exec(background, `INSERT INTO chatts (name, message, id, appid) VALUES ($1, $2, gen_random_uuid(), $3)`,
                        msg.Role, msg.Content, ollamaRequest.AppID)
                if err != nil {
                        return logClientErr(c, http.StatusBadRequest, err)
                }
        }

        c.Logger().Infof("/llmprep/")
        return c.JSON(http.StatusOK, map[string]any{})
}

func llmchat(c echo.Context) error {
	err := errors.New("")
	var ollamaRequest OllamaRequest

	if err = c.Bind(&ollamaRequest); err != nil {
		return logClientErr(c, http.StatusUnprocessableEntity, err)
	}

	if len(ollamaRequest.AppID) == 0 {
		return logClientErr(c, http.StatusUnprocessableEntity,
			fmt.Errorf("invalid appID: %s", ollamaRequest.AppID))
	}

	// insert into DB
	// insert each message into the database
	for _, msg := range ollamaRequest.Messages {
		_, err = chatterDB.Exec(background, `INSERT INTO chatts (name, message, id, appid) VALUES ($1, $2, gen_random_uuid(), $3)`,
			msg.Role, msg.Content, ollamaRequest.AppID)
		if err != nil {
			return logClientErr(c, http.StatusBadRequest, err)
		}
	}

	// reconstruct ollamaRequest to be sent to Ollama:
	// - add context: retrieve all past messages by appID,
	//   incl. the one just received,
	// - convert each back to OllamaMessage, and
	// - insert it into ollamaRequest
	req := c.Request()
	reqCtx := req.Context()
	rows, err := chatterDB.Query(reqCtx, `SELECT name, message FROM chatts WHERE appid = $1 ORDER BY time ASC`, ollamaRequest.AppID)
	if err != nil {
		if rows != nil {
			rows.Close()
		}
		return logServerErr(c, err)
	}

	ollamaRequest.Messages = nil
	var msg OllamaMessage
	for rows.Next() {
		err = rows.Scan(&msg.Role, &msg.Content)
		if err != nil {
			rows.Close()
			return logServerErr(c, err)
		}
		ollamaRequest.Messages = append(ollamaRequest.Messages, msg)
	}

	requestBody, err := json.Marshal(&ollamaRequest) // convert the request to JSON
	if err != nil {
	    return logServerErr(c, err)
	}
	ollama_url := OLLAMA_BASE_URL.String() + "/api/chat"
	request, _ := http.NewRequestWithContext(reqCtx, req.Method, ollama_url, bytes.NewReader(requestBody))
	
	response, err := http.DefaultClient.Do(request))


	if err != nil {
	    return logServerErr(c, err)
	}
	defer func() {
	    _ = response.Body.Close()
	}()
	
	var tokens []string
	wsRegex := regexp.MustCompile("\\s+") 
	
	res := c.Response()
	res.Header().Set(echo.HeaderContentType, "text/event-stream")
	res.Header().Set(echo.HeaderCacheControl, "no-cache")

	reader := bufio.NewReader(response.Body)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if err != io.EOF {
				err_msg, _ := json.Marshal(err.Error())
				_, _ = fmt.Fprintf(res, "event: error\ndata: { \"error\": %s }\n\n", string(err_msg))
				res.Flush()
			}
			break
		}

		var ollamaResponse OllamaResponse
		// deserialize each line into OllamaResponse
		if err = json.Unmarshal([]byte(line), &ollamaResponse); err != nil {
			err_msg, _ := json.Marshal(err.Error())
			_, _ = fmt.Fprintf(res, "event: error\ndata: { \"error\": %s }\n\n", string(err_msg))
			res.Flush()
		} else {
			// append response token to full assistant message
			tokens = append(tokens, wsRegex.ReplaceAllString(ollamaResponse.Message.Content, " "))
			// send NDJSON line as SSE line
			_, _ = fmt.Fprintf(res, "data: %s\n\n", line)
			res.Flush()
		}
	}

	if len(tokens) != 0 {
		var completion = strings.Join(tokens, " ")
		
		// save full response to db, to form part of next prompt's history
		_, err = chatterDB.Exec(background, `INSERT INTO chatts (name, message, id, appid) VALUES ('assistant', $1, gen_random_uuid(), $2)`,
			completion, ollamaRequest.AppID)
		// replace 'assistant' with NULL to test error event

		if err != nil {
			jsonErrMsg, _ := json.Marshal(fmt.Sprintf("%s", err))
			_, _ = fmt.Fprintf(res, "event: error\ndata: { \"error\": %s }\n\n", string(jsonErrMsg))
			res.Flush()
		}
	} // completion


	logOk(c)
	return nil
}

func logServerErr(c echo.Context, err error) error {
	log.Println("[Echo] |", http.StatusInternalServerError, `|`, c.RealIP(), `|`, c.Request().Method, c.Request().RequestURI, err.Error())
	return c.JSON(http.StatusInternalServerError, err.Error())
}

func logClientErr(c echo.Context, sc int, err error) error {
	log.Println("[Echo] |", sc, `|`, c.RealIP(), `|`, c.Request().Method, c.Request().RequestURI, err.Error())
	return c.JSON(sc, err.Error())
}

func logOk(c echo.Context) {
	log.Println("[Echo] |", http.StatusOK, `|`, c.RealIP(), `|`, c.Request().Method, c.Request().RequestURI)
}

func top(c echo.Context) error {
	logOk(c)
	return c.JSON(http.StatusOK, "EECS Reactive chatterd")
}

var OLLAMA_BASE_URL, _ = url.Parse("http://localhost:11434")
var proxy = httputil.NewSingleHostReverseProxy(OLLAMA_BASE_URL)

func llmprompt(c echo.Context) error {
    req := c.Request()
    req.Host = OLLAMA_BASE_URL.Host
    req.URL.Path = "/api/generate"

    proxy.ServeHTTP(c.Response(), req)
    logOk(c)
    return nil
}

func getchatts(c echo.Context) error {
    var chattArr = [][]any{}
    var chatt Chatt

    rows, err := chatterDB.Query(background, `SELECT name, message, id, time FROM chatts ORDER BY time ASC`)
    if err != nil {
      if rows != nil { rows.Close() }
		  return logServerErr(c, err)
    }

    for rows.Next() {
        err = rows.Scan(&chatt.Name, &chatt.Message, &chatt.Id, &chatt.Timestamp)
        if err != nil {
          rows.Close()
          return logServerErr(c, err)
        }
        chattArr = append(chattArr, []any{chatt.Name, chatt.Message, chatt.Id, chatt.Timestamp})
    }

    logOk(c)
    return c.JSON(http.StatusOK, chattArr)
}

func postchatt(c echo.Context) error {
    var chatt Chatt

    if err := c.Bind(&chatt); err != nil {
      return logClientErr(c, http.StatusUnprocessableEntity, err)
    }

    _, err := chatterDB.Exec(background, `INSERT INTO chatts (name, message, id) VALUES ($1, $2, gen_random_uuid())`, chatt.Name, chatt.Message)
    if err != nil {
        return logClientErr(c, http.StatusBadRequest, err)
    }

    logOk(c)
	  return c.JSON(http.StatusOK, struct{}{}) // empty struct instance serialized to empty JSON: {}
}

