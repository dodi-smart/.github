import { expect, it } from 'vitest'
import { card } from './card'

it('renders a card', () => {
  expect(card('a')).toMatchSnapshot()
})

it('renders an empty card', () => {
  expect(card('')).toMatchSnapshot()
})
