package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/filebrowser/filebrowser/auth"
	"github.com/filebrowser/filebrowser/types"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(configCmd)
}

var configCmd = &cobra.Command{
	Use:   "config",
	Short: "Configuration management utility",
	Long:  `Configuration management utility.`,
	Args:  cobra.NoArgs,
	Run: func(cmd *cobra.Command, args []string) {
		cmd.Help()
		os.Exit(0)
	},
}

func addConfigFlags(cmd *cobra.Command) {
	addUserFlags(cmd)
	cmd.Flags().StringP("baseURL", "b", "/", "base url of this installation")
	cmd.Flags().BoolP("signup", "s", false, "allow users to signup")

	cmd.Flags().String("auth.method", string(auth.MethodJSONAuth), "authentication type")
	cmd.Flags().String("auth.header", "", "HTTP header for auth.method=proxy")

	cmd.Flags().String("recaptcha.host", "https://www.google.com", "use another host for ReCAPTCHA. recaptcha.net might be useful in China")
	cmd.Flags().String("recaptcha.key", "", "ReCaptcha site key")
	cmd.Flags().String("recaptcha.secret", "", "ReCaptcha secret")

	cmd.Flags().String("branding.name", "", "replace 'File Browser' by this name")
	cmd.Flags().String("branding.files", "", "path to directory with images and custom styles")
	cmd.Flags().Bool("branding.disableExternal", false, "disable external links such as GitHub links")
}

func getAuthentication(cmd *cobra.Command) (types.AuthMethod, types.Auther) {
	method := types.AuthMethod(mustGetString(cmd, "auth.method"))

	var auther types.Auther
	if method == auth.MethodProxyAuth {
		header := mustGetString(cmd, "auth.header")
		if header == "" {
			panic(errors.New("you must set the flag 'auth.header' for method 'proxy'"))
		}
		auther = auth.ProxyAuth{Header: header}
	}

	if method == auth.MethodNoAuth {
		auther = auth.NoAuth{}
	}

	if method == auth.MethodJSONAuth {
		jsonAuth := auth.JSONAuth{}

		host := mustGetString(cmd, "recaptcha.host")
		key := mustGetString(cmd, "recaptcha.key")
		secret := mustGetString(cmd, "recaptcha.secret")

		if key != "" && secret != "" {
			jsonAuth.ReCaptcha = &auth.ReCaptcha{
				Host:   host,
				Key:    key,
				Secret: secret,
			}
		}

		auther = jsonAuth
	}

	if auther == nil {
		panic(types.ErrInvalidAuthMethod)
	}

	return method, auther
}

func printSettings(s *types.Settings, auther types.Auther) {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)

	fmt.Fprintf(w, "\nBase URL:\t%s\n", s.BaseURL)
	fmt.Fprintf(w, "Sign up:\t%t\n", s.Signup)
	fmt.Fprintf(w, "Auth method:\t%s\n", s.AuthMethod)
	fmt.Fprintln(w, "\nBranding:")
	fmt.Fprintf(w, "\tName:\t%s\n", s.Branding.Name)
	fmt.Fprintf(w, "\tFiles override:\t%s\n", s.Branding.Files)
	fmt.Fprintf(w, "\tDisable external links:\t%t\n", s.Branding.DisableExternal)
	fmt.Fprintln(w, "\nDefaults:")
	fmt.Fprintf(w, "\tScope:\t%s\n", s.Defaults.Scope)
	fmt.Fprintf(w, "\tLocale:\t%s\n", s.Defaults.Locale)
	fmt.Fprintf(w, "\tView mode:\t%s\n", s.Defaults.ViewMode)
	fmt.Fprintf(w, "\tSorting:\n")
	fmt.Fprintf(w, "\t\tBy:\t%s\n", s.Defaults.Sorting.By)
	fmt.Fprintf(w, "\t\tAsc:\t%t\n", s.Defaults.Sorting.Asc)
	fmt.Fprintf(w, "\tPermissions:\n")
	fmt.Fprintf(w, "\t\tAdmin:\t%t\n", s.Defaults.Perm.Admin)
	fmt.Fprintf(w, "\t\tExecute:\t%t\n", s.Defaults.Perm.Execute)
	fmt.Fprintf(w, "\t\tCreate:\t%t\n", s.Defaults.Perm.Create)
	fmt.Fprintf(w, "\t\tRename:\t%t\n", s.Defaults.Perm.Rename)
	fmt.Fprintf(w, "\t\tModify:\t%t\n", s.Defaults.Perm.Modify)
	fmt.Fprintf(w, "\t\tDelete:\t%t\n", s.Defaults.Perm.Delete)
	fmt.Fprintf(w, "\t\tShare:\t%t\n", s.Defaults.Perm.Share)
	fmt.Fprintf(w, "\t\tDownload:\t%t\n", s.Defaults.Perm.Download)
	w.Flush()

	b, err := json.MarshalIndent(auther, "", "  ")
	checkErr(err)
	fmt.Printf("\nAuther configuration (raw):\n\n%s\n\n", string(b))
}
