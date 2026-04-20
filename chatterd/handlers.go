package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"regexp"
	"strings"
	"time"
	"crypto/sha256"
   	"strconv"
   	//...
   	"google.golang.org/api/idtoken"

	"github.com/jackc/pgx/v4"
	"github.com/labstack/echo/v4"
)

type OllamaMessage struct {
	Role      string           `json:"role"`
	Content   string           `json:"content"`
	ToolCalls []OllamaToolCall `json:"tool_calls,omitempty"`
}

type OllamaRequest struct {
	AppID    string             `json:"appID"`
	Model    string             `json:"model"`
	Messages []OllamaMessage    `json:"messages"`
	Stream   bool               `json:"stream"`
	Tools    []OllamaToolSchema `json:"tools,omitempty"`
}

type OllamaResponse struct {
	Model   string        `json:"model"`
	Message OllamaMessage `json:"message"`
}

type Chatt struct {
	Name      string    `json:"name"`
	Message   string    `json:"message"`
	Id        string    `json:"id"`
	Timestamp time.Time `json:"timestamp"`
	Geodata   *string   `json:"geodata"`
}

type Location struct {
	Lat string `json:"lat"`
	Lon string `json:"lon"`
}

type (
	AuthChatt struct {
		ChatterID string `json:"chatterID"`
		Message   string `json:"message"`
	}
	Chatter struct {
		ClientID string `json:"clientID"`
		IdToken  string `json:"idToken"`
	}
)

func adduser(c echo.Context) error {
	var chatter Chatter

	if err := c.Bind(&chatter); err != nil {
		return logClientErr(c, http.StatusUnprocessableEntity, err)
	}

	reqCtx := c.Request().Context()
	idinfo, err := idtoken.Validate(reqCtx, chatter.IdToken, chatter.ClientID)
	if err != nil {
		return logClientErr(c, http.StatusUnauthorized, err)
	}

	username := "Profile NA"
	name := idinfo.Claims["name"]
	if name != nil {
		username = name.(string)
	}

	// compute chatterIDD
	const backendSecret = "ifyougiveamouse"
	now := time.Now().Unix()
	nonce := strconv.FormatInt(now, 10)
	chatterID := fmt.Sprintf("%x", sha256.Sum256([]byte(chatter.IdToken+backendSecret+nonce)))

	exp := idinfo.Expires
	lifetime := min((exp-now)+1, 300) // secs, up to 1800, idToken lifetime

	// add to database
	_, err = chatterDB.Exec(background, `DELETE FROM chatters WHERE $1 > expiration`, now)
	if err != nil {
		return logServerErr(c, err)
	}

	_, err = chatterDB.Exec(background,
		`INSERT INTO chatters (chatterid, username, expiration) VALUES ($1, $2, $3)`,
		chatterID, username, now+lifetime)
	if err != nil {
		return logServerErr(c, err)
	}

	logOk(c)
	return c.JSON(http.StatusOK, map[string]any{"username": username, "chatterID": chatterID, "lifetime": lifetime})
}

func OllamaMessageFromRow(row pgx.Rows, ollamaRequest *OllamaRequest) (*OllamaMessage, error) {
	var msg OllamaMessage
	var toolcalls []byte
	var toolschemas []byte

	err := row.Scan(&msg.Role, &msg.Content, &toolcalls, &toolschemas)
	if err != nil {
		return &msg, err
	}

	if toolcalls != nil {
		// must unmarshal to type to append toolcalls
		var toolCalls []OllamaToolCall
		_ = json.Unmarshal(toolcalls, &toolCalls)
		msg.ToolCalls = append(msg.ToolCalls, toolCalls...)
	}

	if toolschemas != nil {
		// has front-end device tools
		// must unmarshal to type to append device tools to ollamaRequest.tools
		var tools []OllamaToolSchema
		_ = json.Unmarshal(toolschemas, &tools)
		ollamaRequest.Tools = append(ollamaRequest.Tools, tools...)
	}

	return &msg, nil
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

	response, err := http.DefaultClient.Do(request)

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
		winnerCheck := strings.ReplaceAll(completion, " ", "")

		if strings.HasPrefix(winnerCheck, "WINNER!!!:") {
			parts := strings.Split(winnerCheck, ":")
			if len(parts) >= 3 {
				lat := parts[1]
				lon := parts[2]
				_, _ = fmt.Fprintf(res, "event: latlon\ndata: { \"lat\": %s, \"lon\": %s }\n\n", lat, lon)
				res.Flush()
			}
		}

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
		if rows != nil {
			rows.Close()
		}
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

func postmaps(c echo.Context) error {
	var chatt Chatt

	if err := c.Bind(&chatt); err != nil {
		return logClientErr(c, http.StatusUnprocessableEntity, err)
	}

	_, err := chatterDB.Exec(background, `INSERT INTO chatts (name, message, id, geodata) VALUES ($1, $2, gen_random_uuid(), $3)`, chatt.Name, chatt.Message, chatt.Geodata)
	if err != nil {
		return logClientErr(c, http.StatusBadRequest, err)
	}

	logOk(c)
	return c.JSON(http.StatusOK, struct{}{}) // empty struct instance serialized to empty JSON: {}
}

func getmaps(c echo.Context) error {
	var chattArr = [][]any{}
	var chatt Chatt

	rows, err := chatterDB.Query(background, `SELECT name, message, id, time, geodata FROM chatts ORDER BY time ASC`)
	if err != nil {
		if rows != nil {
			rows.Close()
		}
		return logServerErr(c, err)
	}

	for rows.Next() {
		err = rows.Scan(&chatt.Name, &chatt.Message, &chatt.Id, &chatt.Timestamp, &chatt.Geodata)
		if err != nil {
			rows.Close()
			return logServerErr(c, err)
		}
		chattArr = append(chattArr, []any{chatt.Name, chatt.Message, chatt.Id, chatt.Timestamp, chatt.Geodata})
	}

	logOk(c)
	return c.JSON(http.StatusOK, chattArr)
}

func weather(c echo.Context) error {
	var loc Location

	if err := c.Bind(&loc); err != nil {
		return logClientErr(c, http.StatusUnprocessableEntity, err)
	}

	temp, err := getWeather([]string{loc.Lat, loc.Lon})
	if err != nil {
		return logServerErr(c, err)
	}
	logOk(c)
	return c.JSON(http.StatusOK, temp)
}

func llmtools(c echo.Context) error {
	err := errors.New("")
	var ollamaRequest OllamaRequest

	if err = c.Bind(&ollamaRequest); err != nil {
		return logClientErr(c, http.StatusUnprocessableEntity, err)
	}

	if len(ollamaRequest.AppID) == 0 {
		return logClientErr(c, http.StatusUnprocessableEntity,
			fmt.Errorf("invalid appID: %s", ollamaRequest.AppID))
	}

	// convert tools from client as JSON string (client_tools) and save to db;
	var client_tools []byte
	if ollamaRequest.Tools != nil {
		client_tools, _ = json.Marshal(ollamaRequest.Tools)
	}

	// insert into DB
	// insert each message into the database
	for _, msg := range ollamaRequest.Messages {
		_, err = chatterDB.Exec(background, `INSERT INTO chatts (name, message, id, appid, toolschemas) VALUES ($1, $2, gen_random_uuid(), $3, $4)`,
			msg.Role, msg.Content, ollamaRequest.AppID, client_tools)
		if err != nil {
			return logServerErr(c, err)
		}

		// store client_tools only once
		// reset it to empty after first message.
		client_tools = nil
	}

	// reset ollamaRequest.Tools, then append all of chatterd's
	// resident tools to ollamaRequest.Tools;
	// front-end tools will be added back later, as part of reconstructing
	// the appID's context from the db (see OllamaMessageFromRow())
	ollamaRequest.Tools = nil
	for _, tool := range TOOLBOX {
		ollamaRequest.Tools = append(ollamaRequest.Tools, tool.Schema)
	}

	// reconstruct ollamaRequest to be sent to Ollama:
	// - add context: retrieve all past messages by appID,
	//   incl. the one just received,
	// - convert each back to OllamaMessage, and
	// - insert it into ollamaRequest
	req := c.Request()
	reqCtx := req.Context()
	rows, err := chatterDB.Query(reqCtx, `SELECT name, message, toolcalls, toolschemas FROM chatts WHERE appid = $1 ORDER BY time ASC`, ollamaRequest.AppID)
	if err != nil {
		if rows != nil {
			rows.Close()
		}
		return logServerErr(c, err)
	}

	ollamaRequest.Messages = nil
	for rows.Next() {
		msg, err := OllamaMessageFromRow(rows, &ollamaRequest)
		if err != nil {
			rows.Close()
			return logServerErr(c, err)
		}
		ollamaRequest.Messages = append(ollamaRequest.Messages, *msg)
	}

	var tokens []string
	wsRegex := regexp.MustCompile("\\s+")

	res := c.Response()
	res.Header().Set(echo.HeaderContentType, "text/event-stream")
	res.Header().Set(echo.HeaderCacheControl, "no-cache")

	var sendNewPrompt = true
	var tool_result *string
	var tool_err error

	for sendNewPrompt {
		sendNewPrompt = false // assume no resident tool calls

		// construct request
		requestBody, err := json.Marshal(&ollamaRequest) // convert the request to JSON

		if err != nil {
			err_msg, _ := json.Marshal(err.Error())
			_, _ = fmt.Fprintf(res, "event: error\ndata: { \"error\": %s }\n\n", string(err_msg))
			res.Flush()
			return err
		}
		request, _ := http.NewRequestWithContext(reqCtx, req.Method, OLLAMA_BASE_URL.String()+"/api/chat", bytes.NewReader(requestBody))
		// send request
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			err_msg, _ := json.Marshal(err.Error())
			_, _ = fmt.Fprintf(res, "event: error\ndata: { \"error\": %s }\n\n", string(err_msg))
			res.Flush()
			return err
		}

		defer func() {
			_ = response.Body.Close()
		}()

		clear(tokens)       // free used elements
		tokens = tokens[:0] // reset length, keep capacity

		// leave existing code from the line
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
				// is there a tool call?
				if len(ollamaResponse.Message.ToolCalls) != 0 {
					// handle tool calls
					// convert ToolCalls to JSON string (tool_calls) and save to db
					tool_calls, _ := json.Marshal(ollamaResponse.Message.ToolCalls)

					for _, toolCall := range ollamaResponse.Message.ToolCalls {
						// but assuming one tool call per response
						if toolCall.Function.Name == "" {
							continue // LLM miscalled
						}

						// save full response, including tool call(s), to db,
						// to form part of next prompt's history
						_, err =
							chatterDB.Exec(background, `INSERT INTO chatts (name, message, id, appid, toolcalls)
										VALUES ('assistant', $1, gen_random_uuid(), $2, $3)`,
								strings.Join(tokens, ""), ollamaRequest.AppID, tool_calls)
						if err != nil {
							err_msg, _ := json.Marshal(err.Error())
							_, _ = fmt.Fprintf(res, "event: error\ndata: { \"error\": %s }\n\n", string(err_msg))
							res.Flush()
						}

						// clear tokens and tool_calls, we already stored them
						clear(tokens)
						tokens = tokens[:0]
						tool_calls = nil

						// make the tool call
						tool_result, tool_err = toolInvoke(toolCall.Function)
						if tool_err != nil {
							// outcome 1: tool resident but had error
							// send error back to LLM, don't report to frontend
							msg := tool_err.Error()
							tool_result = &msg
						}

						if tool_result != nil {
							// outcomes 1 & 2 (tool call is resident and no error)
							// reuse OllamaMessage to carry tool result
							// to be sent back to Ollama
							// first append the tool call itself
							ollamaRequest.Messages = append(ollamaRequest.Messages, ollamaResponse.Message)
							// then append the result
							ollamaRequest.Messages = append(ollamaRequest.Messages, OllamaMessage{
								Role:    "tool",
								Content: *tool_result,
							})

							// don't send tools multiple times
							ollamaRequest.Tools = nil
							// loop to send tool result back to Ollama
							sendNewPrompt = true

							// save resident tool call result or error message
							_, err = chatterDB.Exec(background, `INSERT INTO chatts (name, message, id, appid)
												VALUES ('tool', $1, gen_random_uuid(), $2)`,
								wsRegex.ReplaceAllString(*tool_result, " "), ollamaRequest.AppID)
							if err != nil {
								err_msg, _ := json.Marshal(err.Error())
								_, _ = fmt.Fprintf(res, "event: error\ndata: { \"error\": %s }\n\n", string(err_msg))
								res.Flush()
							}
							
							break

						} else {
							// outcome 3: tool non resident, forward to
							// front end as 'tool_calls' SSE event
							_, _ = fmt.Fprintf(res, "event: tool_calls\ndata: %s\n\n", line)
							res.Flush()
						}

					} // for toolCall

				} else {
					// no tool call, send NDJSON line as SSE data line
					_, _ = fmt.Fprintf(res, "data: %s\n\n", line)
					res.Flush()
				}
			}
		}
		// to the close brace before logOk(c) here

	} // for sendNewPrompt

	

	if len(tokens) != 0 {
		var completion = strings.Join(tokens, " ")
		winnerCheck := strings.ReplaceAll(completion, " ", "")

		if strings.HasPrefix(winnerCheck, "WINNER!!!:") {
			parts := strings.Split(winnerCheck, ":")
			if len(parts) >= 3 {
				lat := parts[1]
				lon := parts[2]
				_, _ = fmt.Fprintf(res, "event: latlon\ndata: { \"lat\": %s, \"lon\": %s }\n\n", lat, lon)
				res.Flush()
			}
		}

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

func postauth(c echo.Context) error {
	var chatt AuthChatt
	var err error

	if err = c.Bind(&chatt); err != nil {
		return logClientErr(c, http.StatusUnprocessableEntity, err)
	}

	var username string
	var exp int64
	now := time.Now().Unix()
	reqCtx := c.Request().Context()
	err = chatterDB.QueryRow(reqCtx, `SELECT username, expiration FROM chatters WHERE chatterID = $1`, chatt.ChatterID).Scan(&username, &exp)
	if err == pgx.ErrNoRows || now > exp {
		return logClientErr(c, http.StatusUnauthorized, err)
	} else if err != nil {
		return logServerErr(c, err)
	}

	// insert chatt
	_, err = chatterDB.Exec(background, `INSERT INTO chatts (name, message, id) VALUES ($1, $2, gen_random_uuid())`, username, chatt.Message)
	if err != nil {
		return logClientErr(c, http.StatusBadRequest, err)
	}

	logOk(c)
	return c.JSON(http.StatusOK, struct{}{})

}
