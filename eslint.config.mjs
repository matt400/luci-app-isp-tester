// ESLint for the LuCI views (run by .github/workflows/test.yml).
// LuCI JS files are scripts loaded by LuCI's own loader: 'require x' lines
// turn into variables and the file ends with a top-level `return`.
import js from '@eslint/js';
import globals from 'globals';

export default [
	js.configs.recommended,
	{
		files: ['htdocs/**/*.js'],
		languageOptions: {
			ecmaVersion: 2020,
			sourceType: 'script',
			parserOptions: { ecmaFeatures: { globalReturn: true } },
			globals: {
				...globals.browser,
				// LuCI runtime
				L: 'readonly', E: 'readonly', _: 'readonly', N_: 'readonly',
				// 'require ...' modules used by this package
				baseclass: 'readonly', view: 'readonly', form: 'readonly',
				rpc: 'readonly', poll: 'readonly', fs: 'readonly', ui: 'readonly',
				dom: 'readonly', uci: 'readonly', network: 'readonly',
				widgets: 'readonly', diagnose: 'readonly'
			}
		},
		rules: {
			// callbacks often take (section_id, value) and use only one
			'no-unused-vars': ['error', { args: 'none', caughtErrors: 'none' }],
			'no-empty': ['error', { allowEmptyCatch: true }]
		}
	}
];
